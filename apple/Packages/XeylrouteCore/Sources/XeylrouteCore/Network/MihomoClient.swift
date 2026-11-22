import Foundation

public enum MihomoAPIError: LocalizedError, Sendable {
    case notRunning
    case invalidResponse(String)
    case httpError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "代理内核未运行。"
        case .invalidResponse(let msg):
            return msg
        case .httpError(let code, let msg):
            return msg.isEmpty ? "内核接口错误 (HTTP \(code))" : msg
        }
    }
}

/// Async REST and streaming client for Mihomo's authenticated loopback controller.
public final class MihomoClient: Sendable {
    public let host: String
    public let port: UInt16
    public let secret: String
    public let probePort: UInt16

    private let session: URLSession

    public init(host: String = "127.0.0.1", port: UInt16, secret: String, probePort: UInt16) {
        self.host = host
        self.port = port
        self.secret = secret
        self.probePort = probePort

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:] // never proxy loopback controller calls
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: config)
    }

    // MARK: - Snapshots & Control

    public func fetchSnapshot(light: Bool = false) async throws -> MihomoSnapshot {
        async let configJSON = request(method: "GET", pathSegments: ["configs"])
        async let connJSON: JSONValue? = try? request(method: "GET", pathSegments: ["connections"])

        let cfg = try await configJSON
        let conn = await connJSON

        var proxies: [String: MihomoProxySnapshot] = [:]
        var providers: [String: MihomoProviderSnapshot] = [:]

        if !light {
            async let proxiesJSON = request(method: "GET", pathSegments: ["proxies"])
            async let providersJSON: JSONValue? = try? request(method: "GET", pathSegments: ["providers", "proxies"])

            let rawProxies = try await proxiesJSON
            if let map = rawProxies["proxies"]?.objectValue {
                for (name, item) in map {
                    let latestDelay = item["history"]?.arrayValue?.last?["delay"]?.intValue
                    proxies[name] = MihomoProxySnapshot(
                        name: item["name"]?.stringValue ?? name,
                        type: item["type"]?.stringValue ?? "Unknown",
                        now: item["now"]?.stringValue,
                        all: item["all"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                        latestDelay: latestDelay,
                        provider: item["provider"]?.stringValue
                    )
                }
            }

            if let rawProviders = await providersJSON, let map = rawProviders["providers"]?.objectValue {
                let iso = ISO8601DateFormatter()
                for (name, item) in map {
                    let nodes: [ProxyNode] = (item["proxies"]?.arrayValue ?? []).compactMap { p in
                        guard let n = p["name"]?.stringValue else { return nil }
                        return ProxyNode(name: n, type: p["type"]?.stringValue ?? "proxy", provider: name)
                    }
                    let usage: SubscriptionUsage? = item["subscriptionInfo"]?.objectValue.map { info in
                        SubscriptionUsage(
                            upload: Int64(info["Upload"]?.intValue ?? 0),
                            download: Int64(info["Download"]?.intValue ?? 0),
                            total: Int64(info["Total"]?.intValue ?? 0),
                            expire: info["Expire"]?.intValue.map(Int64.init)
                        )
                    }
                    let updatedAt = item["updatedAt"]?.stringValue.flatMap { iso.date(from: $0) }
                    providers[name] = MihomoProviderSnapshot(
                        name: name,
                        vehicleType: item["vehicleType"]?.stringValue,
                        updatedAt: updatedAt,
                        usage: usage,
                        nodes: nodes
                    )
                }
            }
        }

        let totals: ConnectionTotals? = conn.map { data in
            ConnectionTotals(
                downloadTotal: UInt64(max(0, data["downloadTotal"]?.intValue ?? 0)),
                uploadTotal: UInt64(max(0, data["uploadTotal"]?.intValue ?? 0)),
                activeCount: data["connections"]?.arrayValue?.count ?? 0,
                memoryBytes: UInt64(max(0, data["memory"]?.intValue ?? 0))
            )
        }

        return MihomoSnapshot(
            mode: cfg["mode"]?.stringValue.flatMap(RoutingMode.init(rawValue:)),
            mixedPort: cfg["mixed-port"]?.intValue.map { UInt16(clamping: $0) },
            httpPort: cfg["port"]?.intValue.map { UInt16(clamping: $0) },
            socksPort: cfg["socks-port"]?.intValue.map { UInt16(clamping: $0) },
            proxies: proxies,
            providers: providers,
            connections: totals
        )
    }

    public func fetchActiveRoutes() async throws -> [ActiveRoute] {
        let data = try await request(method: "GET", pathSegments: ["connections"])
        let rows = data["connections"]?.arrayValue ?? []
        return rows.compactMap { row in
            let chains = row["chains"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if chains.contains(ProfileStore.probeGroupName) { return nil }
            let meta = row["metadata"]
            return ActiveRoute(
                id: row["id"]?.stringValue ?? UUID().uuidString,
                programPath: meta?["processPath"]?.stringValue ?? "",
                processName: meta?["process"]?.stringValue ?? "",
                host: meta?["host"]?.stringValue ?? "",
                destinationIP: meta?["destinationIP"]?.stringValue ?? "",
                port: meta?["destinationPort"]?.stringValue ?? (meta?["destinationPort"]?.intValue.map(String.init) ?? ""),
                network: meta?["network"]?.stringValue ?? "",
                inbound: meta?["type"]?.stringValue ?? "",
                rule: row["rule"]?.stringValue ?? "",
                rulePayload: row["rulePayload"]?.stringValue ?? "",
                chains: chains
            )
        }
    }

    public func selectProxy(group: String = "GLOBAL", name: String) async throws {
        _ = try await request(
            method: "PUT",
            pathSegments: ["proxies", group],
            body: .object(["name": .string(name)])
        )
    }

    public func setMode(_ mode: RoutingMode) async throws {
        _ = try await request(
            method: "PATCH",
            pathSegments: ["configs"],
            body: .object(["mode": .string(mode.rawValue)])
        )
    }

    public func reloadConfig(atPath path: String) async throws {
        _ = try await request(
            method: "PUT",
            pathSegments: ["configs"],
            query: [("force", "true")],
            body: .object(["path": .string(path)]),
            timeout: 45
        )
    }

    public func refreshProvider(name: String) async throws {
        _ = try await request(
            method: "PUT",
            pathSegments: ["providers", "proxies", name],
            timeout: 45
        )
    }

    public func disableTUN() async {
        _ = try? await request(
            method: "PATCH",
            pathSegments: ["configs"],
            body: .object(["tun": .object(["enable": .bool(false)])]),
            timeout: 2
        )
    }

    // MARK: - Probes (Delay, 1 MB Bandwidth, Website, Exit IP)

    public func measureDelay(
        name: String,
        provider: String?,
        service: ProbeService,
        timeoutMs: Int
    ) async -> DelayMeasurement {
        let segments: [String]
        if let provider, !provider.isEmpty {
            segments = ["providers", "proxies", provider, name, "healthcheck"]
        } else {
            segments = ["proxies", name, "delay"]
        }
        do {
            let result = try await request(
                method: "GET",
                pathSegments: segments,
                query: [("timeout", "\(timeoutMs)"), ("url", service.urlString)],
                timeout: TimeInterval(timeoutMs) / 1000.0 + 3.0
            )
            if let delay = result["delay"]?.intValue, delay > 0 {
                return DelayMeasurement(delayMs: delay)
            }
            return DelayMeasurement(error: "超时")
        } catch {
            return DelayMeasurement(error: error.localizedDescription)
        }
    }

    public func measureDownloadSpeed(nodeName: String) async throws -> Double {
        try await selectProxy(group: ProfileStore.probeGroupName, name: nodeName)
        let proxyConfig = URLSessionConfiguration.ephemeral
        proxyConfig.timeoutIntervalForRequest = 10
        proxyConfig.timeoutIntervalForResource = 12
        #if os(macOS)
        proxyConfig.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(probePort),
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: Int(probePort),
            kCFProxyUsernameKey as String: "routepilot",
            kCFProxyPasswordKey as String: secret,
        ]
        #endif
        let probeSession = URLSession(configuration: proxyConfig)
        defer { probeSession.invalidateAndCancel() }

        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=1000000") else {
            throw MihomoAPIError.invalidResponse("测速地址无效。")
        }
        let started = Date()
        let (data, response) = try await probeSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MihomoAPIError.invalidResponse("测速服务返回异常响应。")
        }
        let elapsed = max(0.001, Date().timeIntervalSince(started))
        return Double(data.count) * 8.0 / (elapsed * 1_000_000.0)
    }

    public func probeWebsite(host: String, localProxyPort: UInt16?) async throws -> (ms: Int, status: Int) {
        let proxySession = makeProxySession(port: localProxyPort, timeout: 8)
        defer { proxySession.invalidateAndCancel() }
        let urlString = host.contains("://") ? host : "https://\(host)"
        guard let url = URL(string: urlString) else {
            throw MihomoAPIError.invalidResponse("域名无效。")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        let started = Date()
        let (_, response) = try await proxySession.data(for: req)
        let ms = Int(Date().timeIntervalSince(started) * 1000.0)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (ms, code)
    }

    public func fetchExitIP(localProxyPort: UInt16?) async throws -> String {
        let proxySession = makeProxySession(port: localProxyPort, timeout: 8)
        defer { proxySession.invalidateAndCancel() }
        guard let url = URL(string: "https://api.ipify.org?format=json") else {
            throw MihomoAPIError.invalidResponse("无法构造出口 IP 查询地址。")
        }
        let (data, _) = try await proxySession.data(from: url)
        let json = try JSONValue.decode(from: data)
        guard let ip = json["ip"]?.stringValue, !ip.isEmpty else {
            throw MihomoAPIError.invalidResponse("出口 IP 响应无效。")
        }
        return ip
    }

    // MARK: - Live Structured Log Stream

    public func logStream() -> AsyncStream<ConnectionLogRow> {
        AsyncStream { continuation in
            let task = Task {
                guard let url = URL(string: "http://\(host):\(port)/logs?level=info&format=structured") else {
                    continuation.finish()
                    return
                }
                var req = URLRequest(url: url)
                req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
                do {
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        continuation.finish()
                        return
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if let data = line.data(using: .utf8),
                           let row = ConnectionLogParser.parse(structuredJSONLine: data)
                        {
                            continuation.yield(row)
                        }
                    }
                } catch {
                    // Stream ended or core stopped
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Low-level HTTP

    private func makeProxySession(port: UInt16?, timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        #if os(macOS)
        if let port, port > 0 {
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: Int(port),
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: Int(port),
            ]
        }
        #endif
        return URLSession(configuration: cfg)
    }

    private func request(
        method: String,
        pathSegments: [String],
        query: [(String, String)] = [],
        body: JSONValue? = nil,
        timeout: TimeInterval = 8
    ) async throws -> JSONValue {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = Int(port)
        let encodedPath = pathSegments
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? $0 }
            .joined(separator: "/")
        comps.percentEncodedPath = "/" + encodedPath
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = comps.url else {
            throw MihomoAPIError.invalidResponse("无效的内核控制接口地址。")
        }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MihomoAPIError.invalidResponse("内核未返回 HTTP 响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let errMsg = (try? JSONValue.decode(from: data))?["message"]?.stringValue
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw MihomoAPIError.httpError(http.statusCode, errMsg)
        }
        if http.statusCode == 204 || data.isEmpty {
            return .null
        }
        return try JSONValue.decode(from: data)
    }
}
