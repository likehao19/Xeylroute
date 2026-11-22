#if os(iOS)
import Foundation
import NetworkExtension

/// iOS runtime backed by `NETunnelProviderManager` and App Group shared configuration.
/// On physical devices signed with the Packet Tunnel entitlement, toggling VPN starts the
/// `XeylrouteTunnel` extension; on iOS Simulator (where NetworkExtension cannot attach a utun),
/// it keeps full profile/subscription/rule management functional and surfaces a clear status note.
public actor IOSTunnelRuntime: CoreRuntime {
    public let profileStore: ProfileStore
    public nonisolated let supportsSystemProxy = false
    public nonisolated let supportsProcessRouting = false
    public nonisolated let supportsFixedSocks = false

    public static let tunnelBundleIdentifier = "app.xeylroute.apple.ios.tunnel"
    public static let appGroupIdentifier = "group.app.xeylroute.apple"

    private let dataDirectory: URL
    private let runtimeConfigURL: URL
    private let logURL: URL
    private var simulatedRunning = false

    public init(dataDirectory: URL = XeylroutePaths.defaultDataDirectory()) throws {
        self.dataDirectory = dataDirectory
        self.profileStore = try ProfileStore(dataDirectory: dataDirectory)
        self.runtimeConfigURL = dataDirectory.appendingPathComponent("runtime-mihomo.json")
        self.logURL = dataDirectory.appendingPathComponent("mihomo.log")
    }

    public func status() async -> CoreStatus {
        let summary = await profileStore.summary()
        let vpnActive = await isTunnelConnected()
        return CoreStatus(
            dataDirectory: dataDirectory.path,
            coreAvailable: true,
            configured: summary.isConfigured,
            running: vpnActive,
            systemProxyEnabled: false,
            tunEnabled: vpnActive,
            tunScope: .all,
            mixedPort: summary.mixedPort,
            httpPort: summary.httpPort,
            socksPort: summary.socksPort,
            coreVersionLabel: "NetworkExtension"
        )
    }

    public func activeClient() async -> MihomoClient? {
        nil
    }

    public func startLocalCore() async throws -> CoreStatus {
        try await startTUN()
    }

    public func startTUN() async throws -> CoreStatus {
        let runtimeData = try await profileStore.buildRuntimeConfig(
            controllerPort: 9090,
            secret: "xeylroute-ios-local",
            probePort: 19091,
            enableTUN: true
        )
        try runtimeData.write(to: runtimeConfigURL, options: .atomic)

        #if targetEnvironment(simulator)
        simulatedRunning = true
        return await status()
        #else
        let manager = try await loadOrCreateManager()
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        try manager.connection.startVPNTunnel(options: [
            "configPath": runtimeConfigURL.path as NSObject,
        ])
        return await status()
        #endif
    }

    public func stopCore() async throws -> CoreStatus {
        #if targetEnvironment(simulator)
        simulatedRunning = false
        return await status()
        #else
        if let manager = try? await loadExistingManager() {
            manager.connection.stopVPNTunnel()
        }
        return await status()
        #endif
    }

    public func reloadIfRunning() async throws {
        guard await isTunnelConnected() else { return }
        let runtimeData = try await profileStore.buildRuntimeConfig(
            controllerPort: 9090,
            secret: "xeylroute-ios-local",
            probePort: 19091,
            enableTUN: true
        )
        try runtimeData.write(to: runtimeConfigURL, options: .atomic)

        #if !targetEnvironment(simulator)
        if let manager = try? await loadExistingManager(),
           let session = manager.connection as? NETunnelProviderSession
        {
            let payload = Data("reload".utf8)
            try? session.sendProviderMessage(payload) { _ in }
        }
        #endif
    }

    public func setSystemProxy(enabled: Bool) async throws -> CoreStatus {
        if enabled {
            return try await startTUN()
        }
        return try await stopCore()
    }

    public func readCoreLogTail() async -> String {
        if let text = try? String(contentsOf: logURL, encoding: .utf8), !text.isEmpty {
            return text.components(separatedBy: .newlines).suffix(200).joined(separator: "\n")
        }
        #if targetEnvironment(simulator)
        return "当前运行在 iOS 模拟器中。真机签名并嵌入 MihomoCore.xcframework 后，此处显示 PacketTunnel 运行日志。"
        #else
        return "暂无隧道日志。"
        #endif
    }

    public func fetchNetworkDetails() async -> NetworkDetails {
        NetworkDetails(localAddresses: [], dnsServers: [], exitIP: nil)
    }

    public func scanRunningProcesses() async -> [RunningProcess] {
        // iOS sandbox does not expose other apps' running processes.
        []
    }

    private func isTunnelConnected() async -> Bool {
        #if targetEnvironment(simulator)
        return simulatedRunning
        #else
        guard let manager = try? await loadExistingManager() else { return false }
        let s = manager.connection.status
        return s == .connected || s == .connecting || s == .reasserting
        #endif
    }

    private func loadExistingManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.tunnelBundleIdentifier
        }
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        if let existing = try await loadExistingManager() {
            return existing
        }
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleIdentifier
        proto.serverAddress = "Xeylroute"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Xeylroute"
        manager.isEnabled = true
        return manager
    }
}
#endif
