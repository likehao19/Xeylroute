import Foundation
import NetworkExtension

/// Protocol decoupling the iOS PacketTunnel extension from the underlying Go/Rust proxy engine.
/// Once `MihomoCore.xcframework` or `Libbox.xcframework` is compiled with `gomobile` and added
/// to the `XeylrouteTunnel` target, provide a concrete `TunnelCoreEngine` implementation here.
public protocol TunnelCoreEngine: AnyObject, Sendable {
    func start(configPath: String, tunFD: Int32) throws
    func reload(configPath: String) throws
    func stop()
}

final class PlaceholderTunnelCoreEngine: TunnelCoreEngine, @unchecked Sendable {
    func start(configPath: String, tunFD: Int32) throws {
        NSLog("[XeylrouteTunnel] Ready to attach embedded core for config: %@ (tunFD=%d)", configPath, tunFD)
    }

    func reload(configPath: String) throws {
        NSLog("[XeylrouteTunnel] Reload requested for config: %@", configPath)
    }

    func stop() {
        NSLog("[XeylrouteTunnel] Stopping embedded core")
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private static let appGroupID = "group.app.xeylroute.apple"
    private let engine: TunnelCoreEngine = PlaceholderTunnelCoreEngine()
    private var activeConfigPath: String?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        let configPath = (options?["configPath"] as? String) ?? defaultSharedConfigPath()
        activeConfigPath = configPath

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
        settings.mtu = 9000

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
        ]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["198.18.0.2"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                completionHandler(error)
                return
            }
            guard let self else {
                completionHandler(nil)
                return
            }
            do {
                let tunFD = (self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32) ?? -1
                try self.engine.start(configPath: configPath, tunFD: tunFD)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        engine.stop()
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: (@Sendable (Data?) -> Void)?
    ) {
        if let command = String(data: messageData, encoding: .utf8),
           command == "reload",
           let path = activeConfigPath
        {
            try? engine.reload(configPath: path)
            completionHandler?(Data("ok".utf8))
            return
        }
        completionHandler?(nil)
    }

    private func defaultSharedConfigPath() -> String {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("core", isDirectory: true)
            .appendingPathComponent("runtime-mihomo.json")
            .path
    }
}
