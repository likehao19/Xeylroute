#if os(macOS)
import Foundation
import Darwin
import Security

// MARK: - macOS System Proxy Manager (with crash-recovery ownership journal)

public enum MacSystemProxyError: LocalizedError, Sendable {
    case commandFailed(String)
    case noServices
    case alreadyOwned

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            return "macOS 系统代理设置失败：\(detail)"
        case .noServices:
            return "未检测到可用的 macOS 网络服务。"
        case .alreadyOwned:
            return "macOS 系统代理已指向该地址，Xeylroute 未重复接管。"
        }
    }
}

public struct MacServiceProxy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var server: String
    public var port: UInt16
}

public struct MacServiceEntry: Codable, Equatable, Sendable {
    public var service: String
    public var http: MacServiceProxy
    public var https: MacServiceProxy
    public var socks: MacServiceProxy
}

public struct MacProxyJournal: Codable, Equatable, Sendable {
    public var previous: [MacServiceEntry]
    public var applied: [MacServiceEntry]
}

public actor MacSystemProxyManager {
    private let journalURL: URL

    public init(dataDirectory: URL) {
        self.journalURL = dataDirectory.appendingPathComponent("system-proxy-recovery.json")
    }

    public func isOwnedByApp() -> Bool {
        guard let journal = readJournal() else { return false }
        let names = journal.applied.map(\.service)
        guard let current = try? query(services: names) else { return false }
        return current == journal.applied
    }

    public func enable(httpPort: UInt16, socksPort: UInt16?) throws {
        // Recover stale journal first if any
        if readJournal() != nil {
            _ = try? restoreIfOwned()
        }
        let services = try targetServices()
        let previous = try query(services: services)
        let desired = previous.map { entry in
            MacServiceEntry(
                service: entry.service,
                http: MacServiceProxy(enabled: true, server: "127.0.0.1", port: httpPort),
                https: MacServiceProxy(enabled: true, server: "127.0.0.1", port: httpPort),
                socks: socksPort.map { MacServiceProxy(enabled: true, server: "127.0.0.1", port: $0) }
                    ?? MacServiceProxy(enabled: false, server: "", port: 0)
            )
        }
        if previous == desired {
            throw MacSystemProxyError.alreadyOwned
        }
        let journal = MacProxyJournal(previous: previous, applied: desired)
        try writeJournal(journal)
        do {
            try apply(desired)
        } catch {
            _ = try? apply(previous)
            try? FileManager.default.removeItem(at: journalURL)
            throw error
        }
    }

    @discardableResult
    public func restoreIfOwned() throws -> Bool {
        guard let journal = readJournal() else { return false }
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let services = journal.applied.map(\.service)
        guard let current = try? query(services: services), current == journal.applied else {
            // Another app changed system proxy; preserve user's newer setting.
            return false
        }
        try apply(journal.previous)
        return true
    }

    private func readJournal() -> MacProxyJournal? {
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        return try? JSONDecoder().decode(MacProxyJournal.self, from: data)
    }

    private func writeJournal(_ journal: MacProxyJournal) throws {
        let data = try JSONEncoder().encode(journal)
        try data.write(to: journalURL, options: .atomic)
    }

    private func targetServices() throws -> [String] {
        let out = try runNetworkSetup(["-listallnetworkservices"])
        let all = out.components(separatedBy: .newlines)
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
        guard !all.isEmpty else { throw MacSystemProxyError.noServices }
        let active = all.filter { hasActiveIP($0) }
        if !active.isEmpty { return active }
        if let wifi = all.first(where: { $0.caseInsensitiveCompare("Wi-Fi") == .orderedSame }) {
            return [wifi]
        }
        return [all[0]]
    }

    private func hasActiveIP(_ service: String) -> Bool {
        guard let out = try? runNetworkSetup(["-getinfo", service]) else { return false }
        return out.components(separatedBy: .newlines).contains { line in
            guard line.hasPrefix("IP address:") else { return false }
            let ip = line.dropFirst("IP address:".count).trimmingCharacters(in: .whitespaces)
            return !ip.isEmpty && ip.caseInsensitiveCompare("none") != .orderedSame
        }
    }

    private func query(services: [String]) throws -> [MacServiceEntry] {
        try services.map { service in
            MacServiceEntry(
                service: service,
                http: parseProxyOutput(try runNetworkSetup(["-getwebproxy", service])),
                https: parseProxyOutput(try runNetworkSetup(["-getsecurewebproxy", service])),
                socks: parseProxyOutput(try runNetworkSetup(["-getsocksfirewallproxy", service]))
            )
        }
    }

    private func apply(_ entries: [MacServiceEntry]) throws {
        for entry in entries {
            try applyOne(entry.service, set: "-setwebproxy", state: "-setwebproxystate", cfg: entry.http)
            try applyOne(entry.service, set: "-setsecurewebproxy", state: "-setsecurewebproxystate", cfg: entry.https)
            try applyOne(entry.service, set: "-setsocksfirewallproxy", state: "-setsocksfirewallproxystate", cfg: entry.socks)
        }
    }

    private func applyOne(_ service: String, set: String, state: String, cfg: MacServiceProxy) throws {
        if cfg.enabled, !cfg.server.isEmpty, cfg.port > 0 {
            _ = try runNetworkSetup([set, service, cfg.server, "\(cfg.port)"])
            _ = try runNetworkSetup([state, service, "on"])
        } else {
            _ = try runNetworkSetup([state, service, "off"])
        }
    }

    private func parseProxyOutput(_ output: String) -> MacServiceProxy {
        var enabled = false
        var server = ""
        var port: UInt16 = 0
        for line in output.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "enabled": enabled = val.lowercased() == "yes"
            case "server": server = val
            case "port": port = UInt16(val) ?? 0
            default: break
            }
        }
        return MacServiceProxy(enabled: enabled, server: server, port: port)
    }

    private func runNetworkSetup(_ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacSystemProxyError.commandFailed(detail.isEmpty ? stdout : detail)
        }
        return stdout
    }
}

// MARK: - macOS Process & Network Scanner

public enum MacProcessScanner {
    private static let systemRoots = [
        "/System/",
        "/usr/libexec/",
        "/usr/sbin/",
        "/sbin/",
        "/Library/Apple/",
    ]

    public static func scanProcesses() -> [RunningProcess] {
        let threads = readThreadCounts()
        guard let output = runCommand("/bin/ps", ["-axo", "pid=,lstart=,comm="]) else { return [] }
        var results: [RunningProcess] = []
        for rawLine in output.components(separatedBy: .newlines) {
            guard let parsed = parsePSLine(rawLine) else { continue }
            guard parsed.path.hasPrefix("/"),
                  !systemRoots.contains(where: { parsed.path.hasPrefix($0) })
            else { continue }
            let url = URL(fileURLWithPath: parsed.path)
            let exe = url.lastPathComponent
            let name = url.deletingPathExtension().lastPathComponent
            results.append(RunningProcess(
                pid: parsed.pid,
                name: name.isEmpty ? exe : name,
                executable: exe,
                path: parsed.path,
                startedAt: parsed.startedAt,
                threadCount: threads[parsed.pid] ?? 1
            ))
        }
        return results.sorted {
            if $0.name.caseInsensitiveCompare($1.name) != .orderedSame {
                return $0.name.caseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.pid < $1.pid
        }
    }

    public static func readNetworkDetails() -> NetworkDetails {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(ifaddr) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let ptr = cursor {
                let flags = Int32(ptr.pointee.ifa_flags)
                let isUp = (flags & IFF_UP) != 0
                let isLoopback = (flags & IFF_LOOPBACK) != 0
                if isUp, !isLoopback, let sa = ptr.pointee.ifa_addr {
                    let family = Int32(sa.pointee.sa_family)
                    if family == AF_INET || family == AF_INET6 {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let len = socklen_t(sa.pointee.sa_len)
                        if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                            if !ip.hasPrefix("fe80:"), !addresses.contains(ip) {
                                addresses.append(ip)
                            }
                        }
                    }
                }
                cursor = ptr.pointee.ifa_next
            }
        }

        var dns: [String] = []
        if let scutil = runCommand("/usr/sbin/scutil", ["--dns"]) {
            for line in scutil.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("nameserver["), let colon = trimmed.firstIndex(of: ":") {
                    let ip = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !ip.isEmpty, !dns.contains(ip) {
                        dns.append(ip)
                    }
                }
            }
        }
        return NetworkDetails(localAddresses: addresses, dnsServers: dns)
    }

    private static func readThreadCounts() -> [Int32: Int] {
        guard let output = runCommand("/bin/ps", ["-M", "-axo", "pid="]) else { return [:] }
        var counts: [Int32: Int] = [:]
        for line in output.components(separatedBy: .newlines) {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                counts[pid, default: 0] += 1
            }
        }
        return counts
    }

    static func parsePSLine(_ line: String) -> (pid: Int32, startedAt: String, path: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Format: <pid> <Dow> <Mon> <Day> <HH:MM:SS> <Year> <command path...>
        var tokens: [Substring] = []
        var idx = trimmed.startIndex
        for _ in 0..<6 {
            while idx < trimmed.endIndex && trimmed[idx].isWhitespace {
                idx = trimmed.index(after: idx)
            }
            guard idx < trimmed.endIndex else { return nil }
            let start = idx
            while idx < trimmed.endIndex && !trimmed[idx].isWhitespace {
                idx = trimmed.index(after: idx)
            }
            tokens.append(trimmed[start..<idx])
        }
        while idx < trimmed.endIndex && trimmed[idx].isWhitespace {
            idx = trimmed.index(after: idx)
        }
        guard idx < trimmed.endIndex, let pid = Int32(tokens[0]) else { return nil }
        let startedAt = tokens[1...5].joined(separator: " ")
        let path = String(trimmed[idx...]).trimmingCharacters(in: .whitespaces)
        return (pid, startedAt, path)
    }

    private static func runCommand(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

// MARK: - macOS Local Mihomo & Privileged TUN Runtime

public actor MacMihomoRuntime: CoreRuntime {
    public let profileStore: ProfileStore
    public nonisolated let supportsSystemProxy = true
    public nonisolated let supportsProcessRouting = true
    public nonisolated let supportsFixedSocks = true

    private let systemProxy: MacSystemProxyManager
    private let dataDirectory: URL
    private let runtimeConfigURL: URL
    private let logURL: URL

    private var localProcess: Process?
    private var tunPID: Int32?
    private var client: MihomoClient?

    public init(dataDirectory: URL = XeylroutePaths.defaultDataDirectory()) throws {
        self.dataDirectory = dataDirectory
        self.profileStore = try ProfileStore(dataDirectory: dataDirectory)
        self.systemProxy = MacSystemProxyManager(dataDirectory: dataDirectory)
        self.runtimeConfigURL = dataDirectory.appendingPathComponent("runtime-mihomo.json")
        self.logURL = dataDirectory.appendingPathComponent("mihomo.log")
    }

    public func recoverAfterCrashIfNeeded() async {
        _ = try? await systemProxy.restoreIfOwned()
    }

    public func status() async -> CoreStatus {
        let summary = await profileStore.summary()
        let isRunning = checkRunning()
        let isTUN = isRunning && tunPID != nil
        let proxyOn = await systemProxy.isOwnedByApp()
        return CoreStatus(
            dataDirectory: dataDirectory.path,
            coreAvailable: findMihomoBinary() != nil,
            configured: summary.isConfigured,
            running: isRunning,
            systemProxyEnabled: proxyOn,
            tunEnabled: isTUN,
            tunScope: summary.tunScope,
            mixedPort: summary.mixedPort,
            httpPort: summary.httpPort,
            socksPort: summary.socksPort,
            coreVersionLabel: "Mihomo v1.19.34"
        )
    }

    public func activeClient() async -> MihomoClient? {
        checkRunning() ? client : nil
    }

    public func startLocalCore() async throws -> CoreStatus {
        guard let binary = findMihomoBinary() else {
            throw ProfileStoreError.missingResource("未找到随包 Mihomo 内核，请先运行 npm run core 或检查应用包资源。")
        }
        try await stopCoreInternal(restoreProxy: false)

        let controllerPort = try findUnusedLoopbackPort()
        let probePort = try findUnusedLoopbackPort()
        let secret = randomHexToken(bytes: 24)

        let runtimeData = try await profileStore.buildRuntimeConfig(
            controllerPort: controllerPort,
            secret: secret,
            probePort: probePort,
            enableTUN: false
        )
        try runtimeData.write(to: runtimeConfigURL, options: .atomic)

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["-d", dataDirectory.path, "-f", runtimeConfigURL.path]
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.uppercased().hasPrefix("CLASH_") {
            env.removeValue(forKey: key)
        }
        process.environment = env
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        let newClient = MihomoClient(port: controllerPort, secret: secret, probePort: probePort)
        self.localProcess = process
        self.client = newClient

        try await waitForControllerReady(newClient)
        return await status()
    }

    public func startTUN() async throws -> CoreStatus {
        guard let binary = findMihomoBinary() else {
            throw ProfileStoreError.missingResource("未找到随包 Mihomo 内核。")
        }
        try await stopCoreInternal(restoreProxy: false)

        let controllerPort = try findUnusedLoopbackPort()
        let probePort = try findUnusedLoopbackPort()
        let secret = randomHexToken(bytes: 24)

        let runtimeData = try await profileStore.buildRuntimeConfig(
            controllerPort: controllerPort,
            secret: secret,
            probePort: probePort,
            enableTUN: true
        )
        try runtimeData.write(to: runtimeConfigURL, options: .atomic)

        let pidFile = dataDirectory.appendingPathComponent("tun-mihomo.pid")
        let cmd = "\(shellQuote(binary.path)) -d \(shellQuote(dataDirectory.path)) -f \(shellQuote(runtimeConfigURL.path)) >\(shellQuote(logURL.path)) 2>&1 & echo $! >\(shellQuote(pidFile.path))"
        let script = "do shell script \"\(appleScriptEscape(cmd))\" with administrator privileges"

        let auth = Process()
        auth.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        auth.arguments = ["-e", script]
        let errPipe = Pipe()
        auth.standardError = errPipe
        try auth.run()
        auth.waitUntilExit()

        guard auth.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if err.contains("-128") || err.lowercased().contains("canceled") {
                throw ProfileStoreError.ioError("已取消 macOS 管理员授权，虚拟网卡未开启。")
            }
            throw ProfileStoreError.ioError("macOS 虚拟网卡提权失败：\(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        if let pidStr = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            self.tunPID = pid
        }
        let newClient = MihomoClient(port: controllerPort, secret: secret, probePort: probePort)
        self.client = newClient
        try await waitForControllerReady(newClient)
        return await status()
    }

    public func stopCore() async throws -> CoreStatus {
        try await stopCoreInternal(restoreProxy: true)
        return await status()
    }

    public func reloadIfRunning() async throws {
        guard checkRunning(), let client else { return }
        let isTUN = tunPID != nil
        let data = try await profileStore.buildRuntimeConfig(
            controllerPort: client.port,
            secret: client.secret,
            probePort: client.probePort,
            enableTUN: isTUN
        )
        try data.write(to: runtimeConfigURL, options: .atomic)
        try await client.reloadConfig(atPath: runtimeConfigURL.path)
    }

    public func setSystemProxy(enabled: Bool) async throws -> CoreStatus {
        if enabled {
            if !checkRunning() {
                _ = try await startLocalCore()
            }
            let summary = await profileStore.summary()
            let httpPort = summary.httpPort > 0 ? summary.httpPort : summary.mixedPort
            guard httpPort > 0 else {
                throw ProfileStoreError.invalidProfile("当前配置未启用本地 HTTP 或 MIXED 监听端口。")
            }
            let socksPort: UInt16? = summary.socksPort > 0 ? summary.socksPort : (summary.mixedPort > 0 ? summary.mixedPort : nil)
            try await systemProxy.enable(httpPort: httpPort, socksPort: socksPort)
        } else {
            _ = try await systemProxy.restoreIfOwned()
        }
        return await status()
    }

    public func readCoreLogTail() async -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else {
            return "暂无内核日志。"
        }
        let lines = text.components(separatedBy: .newlines)
        return lines.suffix(200).joined(separator: "\n")
    }

    public func fetchNetworkDetails() async -> NetworkDetails {
        MacProcessScanner.readNetworkDetails()
    }

    public func scanRunningProcesses() async -> [RunningProcess] {
        MacProcessScanner.scanProcesses()
    }

    // MARK: - Private Helpers

    private func stopCoreInternal(restoreProxy: Bool) async throws {
        if restoreProxy {
            _ = try? await systemProxy.restoreIfOwned()
        }
        if let pid = tunPID {
            await client?.disableTUN()
            let cmd = "kill -TERM \(pid) 2>/dev/null || true"
            let script = "do shell script \"\(appleScriptEscape(cmd))\" with administrator privileges"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
            proc.waitUntilExit()
            tunPID = nil
        }
        if let process = localProcess {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            localProcess = nil
        }
        client = nil
    }

    private func checkRunning() -> Bool {
        if let proc = localProcess, proc.isRunning {
            return true
        }
        if let pid = tunPID, kill(pid, 0) == 0 {
            return true
        }
        if localProcess != nil { localProcess = nil }
        if tunPID != nil { tunPID = nil }
        return false
    }

    private func waitForControllerReady(_ client: MihomoClient) async throws {
        for _ in 0..<25 {
            if (try? await client.fetchSnapshot(light: true)) != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(160))
        }
        throw ProfileStoreError.ioError("Mihomo 内核启动超时，请打开「网络与设置 → 查看日志」检查配置。")
    }

    private func findMihomoBinary() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let resURL = Bundle.main.resourceURL {
            candidates.append(resURL.appendingPathComponent("xeylroute-mihomo"))
            candidates.append(resURL.appendingPathComponent("mihomo"))
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(execDir.appendingPathComponent("xeylroute-mihomo"))
            candidates.append(execDir.appendingPathComponent("mihomo"))
        }
        candidates.append(dataDirectory.appendingPathComponent("mihomo"))

        // Development fallback: locate repo's src-tauri/binaries/xeylroute-mihomo-aarch64-apple-darwin
        let arch = {
            #if arch(arm64)
            return "aarch64-apple-darwin"
            #else
            return "x86_64-apple-darwin"
            #endif
        }()
        var probe = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<5 {
            let repoBin = probe.appendingPathComponent("src-tauri/binaries/xeylroute-mihomo-\(arch)")
            candidates.append(repoBin)
            probe.deleteLastPathComponent()
        }

        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    private func findUnusedLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProfileStoreError.ioError("无法分配回环端口。") }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw ProfileStoreError.ioError("无法绑定回环端口。") }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else { throw ProfileStoreError.ioError("无法读取分配的回环端口。") }
        return UInt16(bigEndian: addr.sin_port)
    }

    private func randomHexToken(bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        return buffer.map { String(format: "%02x", $0) }.joined()
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
#endif
