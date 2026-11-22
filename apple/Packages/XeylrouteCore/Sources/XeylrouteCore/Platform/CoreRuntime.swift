import Foundation

/// Platform-agnostic runtime contract implemented by:
/// - `MacMihomoRuntime` on macOS (local bundled Mihomo process + `networksetup` system proxy + privileged TUN)
/// - `IOSTunnelRuntime` on iOS (`NETunnelProviderManager` + App Group shared config + XCFramework hook)
public protocol CoreRuntime: Sendable {
    var profileStore: ProfileStore { get }
    var supportsSystemProxy: Bool { get }
    var supportsProcessRouting: Bool { get }
    var supportsFixedSocks: Bool { get }

    func status() async -> CoreStatus
    func activeClient() async -> MihomoClient?
    func startLocalCore() async throws -> CoreStatus
    func startTUN() async throws -> CoreStatus
    func stopCore() async throws -> CoreStatus
    func reloadIfRunning() async throws
    func setSystemProxy(enabled: Bool) async throws -> CoreStatus
    func readCoreLogTail() async -> String
    func fetchNetworkDetails() async -> NetworkDetails
    func scanRunningProcesses() async -> [RunningProcess]
}

public enum XeylroutePaths {
    public static func defaultDataDirectory() -> URL {
        #if os(iOS)
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.xeylroute.apple") {
            return groupURL.appendingPathComponent("core", isDirectory: true)
        }
        #endif
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Xeylroute", isDirectory: true)
            .appendingPathComponent("core", isDirectory: true)
    }
}
