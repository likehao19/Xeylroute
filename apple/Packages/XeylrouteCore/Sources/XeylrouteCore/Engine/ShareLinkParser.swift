import Foundation

public enum ShareLinkError: LocalizedError, Sendable {
    case empty
    case unsupportedScheme(String)
    case invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "请输入节点分享链接。"
        case .unsupportedScheme(let scheme):
            return "暂不支持 \(scheme):// 协议链接。"
        case .invalidFormat(let message):
            return message
        }
    }
}

public enum ShareLinkParser {
    private static let supportedSchemes: Set<String> = [
        "ss", "vmess", "vless", "trojan", "hysteria2", "hy2", "tuic",
    ]

    public static func looksLikeShareLinks(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if containsSupportedScheme(trimmed) { return true }
        if !trimmed.contains("://"), let decoded = decodeBase64(trimmed) {
            return containsSupportedScheme(decoded)
        }
        return false
    }

    public static func parseBundle(_ input: String, requireAll: Bool = false) throws -> [JSONValue] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ShareLinkError.empty }

        let source: String
        if !trimmed.contains("://"), let decoded = decodeBase64(trimmed) {
            source = decoded
        } else {
            source = trimmed
        }

        var nodes: [JSONValue] = []
        var lastError: Error?
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            do {
                nodes.append(try parseSingleLink(line))
            } catch {
                if requireAll { throw error }
                lastError = error
            }
        }
        if nodes.isEmpty {
            throw lastError ?? ShareLinkError.invalidFormat("未识别到有效的代理节点链接。")
        }
        return nodes
    }

    public static func parseSingleLink(_ line: String) throws -> JSONValue {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "://") else {
            throw ShareLinkError.invalidFormat("不支持的节点链接格式。")
        }
        let scheme = trimmed[..<range.lowerBound].lowercased()
        switch scheme {
        case "ss": return try parseSS(trimmed)
        case "vmess": return try parseVMess(trimmed)
        case "vless": return try parseVLESS(trimmed)
        case "trojan": return try parseTrojan(trimmed)
        case "hysteria2", "hy2": return try parseHysteria2(trimmed)
        case "tuic": return try parseTUIC(trimmed)
        default: throw ShareLinkError.unsupportedScheme(scheme)
        }
    }

    // MARK: - Protocol Parsers

    private static func parseSS(_ line: String) throws -> JSONValue {
        let body = String(line.dropFirst("ss://".count))
        let fragSplit = body.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let main = String(fragSplit[0])
        let frag = fragSplit.count == 2 ? percentDecode(String(fragSplit[1])) : nil

        let querySplit = main.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let addrPart = String(querySplit[0])
        let queryPart = querySplit.count == 2 ? String(querySplit[1]) : nil

        let method: String
        let password: String
        let server: String
        let port: Int

        if let atIdx = addrPart.firstIndex(of: "@") {
            let userInfo = String(addrPart[..<atIdx])
            let hostPort = String(addrPart[addrPart.index(after: atIdx)...])
            let decodedCred = userInfo.contains(":")
                ? percentDecode(userInfo)
                : (decodeBase64(userInfo) ?? percentDecode(userInfo))
            guard let colon = decodedCred.firstIndex(of: ":") else {
                throw ShareLinkError.invalidFormat("SS 链接缺少加密方式或密码。")
            }
            method = String(decodedCred[..<colon])
            password = String(decodedCred[decodedCred.index(after: colon)...])
            (server, port) = try parseHostPort(hostPort, errorPrefix: "SS")
        } else {
            guard let decoded = decodeBase64(addrPart) else {
                throw ShareLinkError.invalidFormat("无法解码 SS Base64 节点链接。")
            }
            guard let atIdx = decoded.lastIndex(of: "@") else {
                throw ShareLinkError.invalidFormat("SS 链接格式无效。")
            }
            let cred = String(decoded[..<atIdx])
            let hostPort = String(decoded[decoded.index(after: atIdx)...])
            guard let colon = cred.firstIndex(of: ":") else {
                throw ShareLinkError.invalidFormat("SS 链接缺少加密方式或密码。")
            }
            method = String(cred[..<colon])
            password = String(cred[cred.index(after: colon)...])
            (server, port) = try parseHostPort(hostPort, errorPrefix: "SS")
        }

        let name = frag?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "SS · \(server):\(port)"

        var node: [String: JSONValue] = [
            "name": .string(name),
            "type": .string("ss"),
            "server": .string(server),
            "port": .int(Int64(port)),
            "cipher": .string(method),
            "password": .string(password),
            "udp": .bool(true),
        ]

        if let queryPart, let params = parseQuery(queryPart), let pluginRaw = params["plugin"]?.nonEmpty {
            let parts = pluginRaw.split(separator: ";").map(String.init)
            if let first = parts.first {
                let pluginName = (first == "obfs-local" || first == "simple-obfs") ? "obfs" : first
                node["plugin"] = .string(pluginName)
                var opts: [String: JSONValue] = [:]
                for kv in parts.dropFirst() {
                    if let eq = kv.firstIndex(of: "=") {
                        let rawKey = String(kv[..<eq])
                        let val = String(kv[kv.index(after: eq)...])
                        let key = rawKey == "obfs" ? "mode" : (rawKey == "obfs-host" ? "host" : rawKey)
                        opts[key] = .string(val)
                    }
                }
                if !opts.isEmpty {
                    node["plugin-opts"] = .object(opts)
                }
            }
        }
        return .object(node)
    }

    private static func parseVMess(_ line: String) throws -> JSONValue {
        let encoded = String(line.dropFirst("vmess://".count))
        guard let raw = decodeBase64(encoded), let data = raw.data(using: .utf8),
              let payload = try? JSONValue.decode(from: data)
        else {
            throw ShareLinkError.invalidFormat("无法解码 VMess Base64 或 JSON 内容。")
        }
        guard let server = payload["add"]?.stringValue?.nonEmpty else {
            throw ShareLinkError.invalidFormat("VMess 缺少服务器地址。")
        }
        guard let port = payload["port"]?.intValue, port > 0, port <= 65535 else {
            throw ShareLinkError.invalidFormat("VMess 端口号无效。")
        }
        guard let uuid = payload["id"]?.stringValue?.nonEmpty else {
            throw ShareLinkError.invalidFormat("VMess 缺少 UUID。")
        }
        let alterID = payload["aid"]?.intValue ?? 0
        let cipher = payload["scy"]?.stringValue?.nonEmpty
            ?? payload["cipher"]?.stringValue?.nonEmpty
            ?? "auto"
        let name = payload["ps"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "VMess · \(server):\(port)"

        var node: [String: JSONValue] = [
            "name": .string(name),
            "type": .string("vmess"),
            "server": .string(server),
            "port": .int(Int64(port)),
            "uuid": .string(uuid),
            "alterId": .int(Int64(alterID)),
            "cipher": .string(cipher),
            "udp": .bool(true),
        ]

        if payload["tls"]?.stringValue?.lowercased() == "tls" || payload["tls"]?.boolValue == true {
            node["tls"] = .bool(true)
            if let sni = payload["sni"]?.stringValue?.nonEmpty ?? payload["host"]?.stringValue?.nonEmpty {
                node["servername"] = .string(sni)
            }
        }
        if let fp = payload["fp"]?.stringValue?.nonEmpty {
            node["client-fingerprint"] = .string(fp)
        }

        var params: [String: String] = [:]
        if let net = payload["net"]?.stringValue?.nonEmpty { params["type"] = net }
        if let path = payload["path"]?.stringValue?.nonEmpty {
            params["path"] = path
            params["servicename"] = path
        }
        if let host = payload["host"]?.stringValue?.nonEmpty { params["host"] = host }
        applyTransport(&node, params: params)
        return .object(node)
    }

    private static func parseVLESS(_ line: String) throws -> JSONValue {
        guard let comps = URLComponents(string: line) else {
            throw ShareLinkError.invalidFormat("VLESS 链接格式无效。")
        }
        let server = try requireHost(comps)
        let port = comps.port ?? 443
        let uuid = percentDecode(comps.user ?? "")
        guard !uuid.isEmpty else {
            throw ShareLinkError.invalidFormat("VLESS 链接缺少 UUID。")
        }
        let params = queryDict(comps)
        let name = fragmentName(comps, fallback: "VLESS · \(server):\(port)")

        var node: [String: JSONValue] = [
            "name": .string(name),
            "type": .string("vless"),
            "server": .string(server),
            "port": .int(Int64(port)),
            "uuid": .string(uuid),
            "udp": .bool(true),
        ]

        if let flow = params["flow"]?.nonEmpty {
            node["flow"] = .string(flow)
        }
        let security = (params["security"] ?? "").lowercased()
        if security == "tls" || security == "reality" {
            node["tls"] = .bool(true)
        }
        if let sni = params["sni"]?.nonEmpty ?? params["servername"]?.nonEmpty {
            node["servername"] = .string(sni)
        }
        if let fp = params["fp"]?.nonEmpty {
            node["client-fingerprint"] = .string(fp)
        }
        if let alpn = params["alpn"]?.nonEmpty {
            node["alpn"] = .array(splitCSV(alpn).map(JSONValue.string))
        }
        if isTruthy(params["allowinsecure"] ?? params["insecure"]) {
            node["skip-cert-verify"] = .bool(true)
        }
        if security == "reality" {
            var reality: [String: JSONValue] = [:]
            if let pbk = params["pbk"]?.nonEmpty { reality["public-key"] = .string(pbk) }
            if let sid = params["sid"]?.nonEmpty { reality["short-id"] = .string(sid) }
            if !reality.isEmpty { node["reality-opts"] = .object(reality) }
        }
        applyTransport(&node, params: params)
        return .object(node)
    }

    private static func parseTrojan(_ line: String) throws -> JSONValue {
        guard let comps = URLComponents(string: line) else {
            throw ShareLinkError.invalidFormat("Trojan 链接格式无效。")
        }
        let server = try requireHost(comps)
        let port = comps.port ?? 443
        let password = percentDecode(comps.user ?? "")
        guard !password.isEmpty else {
            throw ShareLinkError.invalidFormat("Trojan 链接缺少密码。")
        }
        let params = queryDict(comps)
        let name = fragmentName(comps, fallback: "Trojan · \(server):\(port)")

        var node: [String: JSONValue] = [
            "name": .string(name),
            "type": .string("trojan"),
            "server": .string(server),
            "port": .int(Int64(port)),
            "password": .string(password),
            "udp": .bool(true),
        ]

        if let sni = params["sni"]?.nonEmpty ?? params["peer"]?.nonEmpty {
            node["sni"] = .string(sni)
        }
        if let alpn = params["alpn"]?.nonEmpty {
            node["alpn"] = .array(splitCSV(alpn).map(JSONValue.string))
        }
        if let fp = params["fp"]?.nonEmpty {
            node["client-fingerprint"] = .string(fp)
        }
        if isTruthy(params["allowinsecure"] ?? params["insecure"]) {
            node["skip-cert-verify"] = .bool(true)
        }
        applyTransport(&node, params: params)
        return .object(node)
    }

    private static func parseHysteria2(_ line: String) throws -> JSONValue {
        let normalized = line.lowercased().hasPrefix("hy2://")
            ? "hysteria2://" + line.dropFirst("hy2://".count)
            : line
        guard let comps = URLComponents(string: normalized) else {
            throw ShareLinkError.invalidFormat("Hysteria2 链接格式无效。")
        }
        let server = try requireHost(comps)
        let port = comps.port ?? 443
        let user = percentDecode(comps.user ?? "")
        let password = comps.password.map { "\(user):\(percentDecode($0))" } ?? user
        guard !password.isEmpty else {
            throw ShareLinkError.invalidFormat("Hysteria2 链接缺少认证密码。")
        }
        let params = queryDict(comps)
        let name = fragmentName(comps, fallback: "Hysteria2 · \(server):\(port)")

        var node: [String: JSONValue] = [
            "name": .string(name),
            "type": .string("hysteria2"),
            "server": .string(server),
            "port": .int(Int64(port)),
            "password": .string(password),
        ]
        if let sni = params["sni"]?.nonEmpty { node["sni"] = .string(sni) }
        if let obfs = params["obfs"]?.nonEmpty { node["obfs"] = .string(obfs) }
        if let obfsPw = params["obfs-password"]?.nonEmpty { node["obfs-password"] = .string(obfsPw) }
        if let alpn = params["alpn"]?.nonEmpty {
            node["alpn"] = .array(splitCSV(alpn).map(JSONValue.string))
        }
        if isTruthy(params["insecure"] ?? params["allowinsecure"]) {
            node["skip-cert-verify"] = .bool(true)
        }
        return .object(node)
    }

    private static func parseTUIC(_ line: String) throws -> JSONValue {
        guard let comps = URLComponents(string: line) else {
            throw ShareLinkError.invalidFormat("TUIC 链接格式无效。")
        }
        let server = try requireHost(comps)
        let port = comps.port ?? 443
        let uuid = percentDecode(comps.user ?? "")
        let password = comps.password.map(percentDecode) ?? ""
        guard !uuid.isEmpty else {
            throw ShareLinkError.invalidFormat("TUIC 链接缺少 UUID。")
        }
        let params = queryDict(comps)
        let name = fragmentName(comps, fallback: "TUIC · \(server):\(port)")

        var node: [String: JSONValue] = [
            "name": .string(name),
            "type": .string("tuic"),
            "server": .string(server),
            "port": .int(Int64(port)),
            "uuid": .string(uuid),
        ]
        if !password.isEmpty { node["password"] = .string(password) }
        if let sni = params["sni"]?.nonEmpty { node["sni"] = .string(sni) }
        if let alpn = params["alpn"]?.nonEmpty {
            node["alpn"] = .array(splitCSV(alpn).map(JSONValue.string))
        }
        if let cc = params["congestion_control"]?.nonEmpty {
            node["congestion-controller"] = .string(cc)
        }
        if let relay = params["udp_relay_mode"]?.nonEmpty {
            node["udp-relay-mode"] = .string(relay)
        }
        if isTruthy(params["allow_insecure"] ?? params["insecure"]) {
            node["skip-cert-verify"] = .bool(true)
        }
        return .object(node)
    }

    // MARK: - Helpers

    private static func applyTransport(_ node: inout [String: JSONValue], params: [String: String]) {
        let network = (params["type"] ?? params["net"] ?? "tcp").lowercased()
        switch network {
        case "ws":
            node["network"] = .string("ws")
            var opts: [String: JSONValue] = [:]
            if let path = params["path"]?.nonEmpty { opts["path"] = .string(path) }
            if let host = params["host"]?.nonEmpty { opts["headers"] = .object(["Host": .string(host)]) }
            if !opts.isEmpty { node["ws-opts"] = .object(opts) }
        case "grpc":
            node["network"] = .string("grpc")
            if let svc = params["servicename"]?.nonEmpty
                ?? params["service-name"]?.nonEmpty
                ?? params["path"]?.nonEmpty
            {
                node["grpc-opts"] = .object(["grpc-service-name": .string(svc)])
            }
        case "h2", "http":
            node["network"] = .string("h2")
            var opts: [String: JSONValue] = [:]
            if let path = params["path"]?.nonEmpty { opts["path"] = .string(path) }
            if let host = params["host"]?.nonEmpty {
                opts["host"] = .array(splitCSV(host).map(JSONValue.string))
            }
            if !opts.isEmpty { node["h2-opts"] = .object(opts) }
        default:
            break
        }
    }

    private static func containsSupportedScheme(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let range = trimmed.range(of: "://") else { return false }
            return supportedSchemes.contains(trimmed[..<range.lowerBound].lowercased())
        }
    }

    private static func parseHostPort(_ raw: String, errorPrefix: String) throws -> (String, Int) {
        guard let comps = URLComponents(string: "http://\(raw)") else {
            throw ShareLinkError.invalidFormat("\(errorPrefix) 节点服务器地址或端口无效。")
        }
        let host = try requireHost(comps)
        guard let port = comps.port, port > 0, port <= 65535 else {
            throw ShareLinkError.invalidFormat("\(errorPrefix) 节点缺少端口号。")
        }
        return (host, port)
    }

    private static func requireHost(_ comps: URLComponents) throws -> String {
        guard let host = comps.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else {
            throw ShareLinkError.invalidFormat("节点链接缺少服务器地址。")
        }
        return host
    }

    private static func queryDict(_ comps: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            result[item.name.lowercased()] = item.value ?? ""
        }
        return result
    }

    private static func parseQuery(_ query: String) -> [String: String]? {
        guard let comps = URLComponents(string: "http://127.0.0.1/?\(query)") else { return nil }
        return queryDict(comps)
    }

    private static func fragmentName(_ comps: URLComponents, fallback: String) -> String {
        guard let frag = comps.percentEncodedFragment else { return fallback }
        return percentDecode(frag).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fallback
    }

    private static func splitCSV(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let lower = value?.lowercased() else { return false }
        return lower == "1" || lower == "true" || lower == "yes"
    }

    private static func percentDecode(_ raw: String) -> String {
        raw.removingPercentEncoding ?? raw
    }

    public static func decodeBase64(_ input: String) -> String? {
        var cleaned = input.filter { !$0.isWhitespace }
        guard !cleaned.isEmpty else { return nil }
        cleaned = cleaned.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = cleaned.count % 4
        if remainder != 0 {
            cleaned += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
