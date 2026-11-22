import Foundation
import Observation
import SwiftUI
import XeylrouteCore

public enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case connect
    case nodes
    case split
    case logs
    case subscriptions
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .connect: return "连接"
        case .nodes: return "代理组与节点"
        case .split: return "分流与程序"
        case .logs: return "连接记录"
        case .subscriptions: return "订阅管理"
        case .settings: return "网络与设置"
        }
    }

    public var shortTitle: String {
        switch self {
        case .connect: return "连接"
        case .nodes: return "节点"
        case .split: return "分流"
        case .logs: return "记录"
        case .subscriptions: return "订阅"
        case .settings: return "设置"
        }
    }

    public var systemImage: String {
        switch self {
        case .connect: return "bolt.horizontal.circle.fill"
        case .nodes: return "point.3.connected.trianglepath.dotted"
        case .split: return "arrow.triangle.branch"
        case .logs: return "list.bullet.rectangle.portrait"
        case .subscriptions: return "square.stack.3d.up.fill"
        case .settings: return "gearshape.fill"
        }
    }

    public var tint: Color {
        switch self {
        case .connect: return .blue
        case .nodes: return .cyan
        case .split: return .purple
        case .logs: return .green
        case .subscriptions: return .orange
        case .settings: return .secondary
        }
    }
}

public enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public struct ToastMessage: Equatable, Identifiable {
    public let id = UUID()
    public let text: String
    public let isError: Bool
}

@Observable
@MainActor
public final class AppState {
    public let runtime: any CoreRuntime

    // Navigation & Appearance
    public var selectedDestination: AppDestination = .connect
    public var searchText: String = ""
    public var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "xeylroute-apple-appearance") }
    }

    // Core & Profile State
    public var status = CoreStatus()
    public var profile = ProfileSummary()
    public var snapshot: MihomoSnapshot?
    public var networkDetails = NetworkDetails()
    public var isBusy = false
    public var toast: ToastMessage?

    // Probes & Speeds
    public var probeService: ProbeService {
        didSet { UserDefaults.standard.set(probeService.rawValue, forKey: "xeylroute-probe-service") }
    }
    public var probeTimeoutMs: Int {
        didSet { UserDefaults.standard.set(probeTimeoutMs, forKey: "xeylroute-probe-timeout") }
    }
    public var probeConcurrency: Int {
        didSet { UserDefaults.standard.set(probeConcurrency, forKey: "xeylroute-probe-concurrency") }
    }
    private(set) var refreshingProviders: Set<String> = []
    private(set) var subscriptionErrors: [String: String] = [:]
    public var nodeDelays: [String: DelayMeasurement] = [:]
    public var testingNodes: Set<String> = []
    public var isBatchProbing = false
    public var websites: [WebsiteProbeItem] = WebsiteProbeItem.defaultCatalog

    // Logs, Active Routes & Processes
    public var connectionLogs: [ConnectionLogRow] = []
    public var activeRoutes: [ActiveRoute] = []
    public var runningProcesses: [RunningProcess] = []
    public var groupedApps: [GroupedRunningApp] = []

    // Live Telemetry
    public var trafficTracker = TrafficTracker(maxSamples: 60)
    public var currentDownRate: Double = 0
    public var currentUpRate: Double = 0
    public var sessionStartDate: Date?
    public var elapsedSeconds: Int = 0

    // Private tasks
    private var pollTask: Task<Void, Never>?
    private var logStreamTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var tickCounter = 0

    public init(runtime: any CoreRuntime) {
        self.runtime = runtime
        let savedAppearance = UserDefaults.standard.string(forKey: "xeylroute-apple-appearance") ?? "auto"
        self.appearance = AppearanceMode(rawValue: savedAppearance) ?? .auto
        let savedProbe = UserDefaults.standard.string(forKey: "xeylroute-probe-service") ?? "google"
        self.probeService = ProbeService(rawValue: savedProbe) ?? .google
        let savedTimeout = UserDefaults.standard.integer(forKey: "xeylroute-probe-timeout")
        self.probeTimeoutMs = [2000, 5000, 7000].contains(savedTimeout) ? savedTimeout : 5000
        let savedWorkers = UserDefaults.standard.integer(forKey: "xeylroute-probe-concurrency")
        self.probeConcurrency = [2, 4, 8, 16].contains(savedWorkers) ? savedWorkers : 8
    }

    public static func makeDefault() -> AppState {
        #if os(macOS)
        let runtime = try! MacMihomoRuntime()
        #else
        let runtime = try! IOSTunnelRuntime()
        #endif
        return AppState(runtime: runtime)
    }

    // MARK: - Lifecycle

    public func bootstrap() async {
        #if os(macOS)
        if let mac = runtime as? MacMihomoRuntime {
            await mac.recoverAfterCrashIfNeeded()
        }
        #endif
        await refreshAll(fullSnapshot: true)
        await refreshProcesses()
        await refreshNetworkDetails()
        startPollingLoop()
    }

    public func shutdown() async {
        pollTask?.cancel()
        logStreamTask?.cancel()
        _ = try? await runtime.stopCore()
    }

    private func startPollingLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { break }
                self.tickCounter += 1
                if self.status.running {
                    if let start = self.sessionStartDate {
                        self.elapsedSeconds = max(0, Int(Date().timeIntervalSince(start)))
                    }
                    await self.refreshAll(fullSnapshot: self.tickCounter % 5 == 0)
                }
            }
        }
    }

    private func restartLogStreamIfNeeded() {
        guard status.running else {
            logStreamTask?.cancel()
            logStreamTask = nil
            return
        }
        guard logStreamTask == nil else { return }
        logStreamTask = Task { [weak self] in
            guard let self, let client = await self.runtime.activeClient() else { return }
            for await row in client.logStream() {
                if Task.isCancelled { break }
                self.connectionLogs.insert(row, at: 0)
                if self.connectionLogs.count > 500 {
                    self.connectionLogs.removeLast(self.connectionLogs.count - 500)
                }
            }
            self.logStreamTask = nil
        }
    }

    // MARK: - Derived Properties

    public var currentGlobalExit: String {
        snapshot?.proxies["GLOBAL"]?.now
            ?? snapshot?.proxies["AUTO"]?.now
            ?? profile.standaloneNodes.first?.name
            ?? "AUTO"
    }

    public var selectableNodes: [ProxyNode] {
        var result: [ProxyNode] = [
            ProxyNode(name: "AUTO", type: "自动优选", isPolicy: true, currentSelection: snapshot?.proxies["AUTO"]?.now),
            ProxyNode(name: "DIRECT", type: "直连", isPolicy: true),
            ProxyNode(name: "REJECT", type: "阻断", isPolicy: true),
        ]
        var seen = Set(result.map(\.name))

        if let activeScope = profile.subscriptionScope ?? profile.providers.first?.name {
            let liveNodes = snapshot?.providers[activeScope]?.nodes
            let cachedNodes = profile.providers.first(where: { $0.name == activeScope })?.nodes ?? []
            for node in (liveNodes ?? cachedNodes) where !seen.contains(node.name) {
                seen.insert(node.name)
                result.append(node)
            }
        }

        for node in profile.standaloneNodes where !seen.contains(node.name) {
            seen.insert(node.name)
            result.append(node)
        }
        return result
    }

    public var activeRuleCount: Int {
        profile.rules.filter { !$0.isDefaultMatch && $0.enabled }.count
    }

    public var totalTrafficBytes: Int64 {
        guard let conn = snapshot?.connections else { return 0 }
        return Int64(conn.downloadTotal + conn.uploadTotal)
    }

    public var statusBadgeTitle: String {
        if isBusy { return "更新中…" }
        if status.tunEnabled && status.systemProxyEnabled { return "系统代理 + 虚拟网卡" }
        if status.tunEnabled { return "虚拟网卡运行中" }
        if status.systemProxyEnabled { return "系统代理已开启" }
        if status.running { return "仅本地监听" }
        if status.configured { return "未连接" }
        return profile.providers.isEmpty ? "待导入配置" : "等待订阅节点"
    }

    // MARK: - Refresh

    public func refreshAll(fullSnapshot: Bool = true) async {
        let newStatus = await runtime.status()
        let newProfile = await runtime.profileStore.summary()
        let wasRunning = status.running
        status = newStatus
        profile = newProfile

        if newStatus.running {
            if !wasRunning || sessionStartDate == nil {
                sessionStartDate = Date()
            }
            if let client = await runtime.activeClient(),
               let snap = try? await client.fetchSnapshot(light: !fullSnapshot)
            {
                if fullSnapshot || snapshot == nil {
                    snapshot = snap
                } else {
                    snapshot?.mode = snap.mode
                    snapshot?.connections = snap.connections
                }
                let rates = trafficTracker.record(totals: snap.connections)
                currentDownRate = rates.down
                currentUpRate = rates.up
            }
            restartLogStreamIfNeeded()
        } else {
            sessionStartDate = nil
            elapsedSeconds = 0
            snapshot = nil
            currentDownRate = 0
            currentUpRate = 0
            trafficTracker.reset()
            restartLogStreamIfNeeded()
        }
    }

    public func refreshProcesses() async {
        guard runtime.supportsProcessRouting else { return }
        let procs = await runtime.scanRunningProcesses()
        runningProcesses = procs
        groupedApps = RunningAppGrouper.group(procs)
    }

    public func refreshNetworkDetails() async {
        var details = await runtime.fetchNetworkDetails()
        details.exitIP = networkDetails.exitIP
        networkDetails = details
    }

    public func refreshActiveRoutes() async {
        guard let client = await runtime.activeClient() else {
            activeRoutes = []
            return
        }
        do {
            activeRoutes = try await client.fetchActiveRoutes()
        } catch {
            notify(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Core & Network Actions

    public func toggleLocalCore() async {
        await performBusy {
            if self.status.running {
                self.status = try await self.runtime.stopCore()
                self.notify("代理内核已停止")
            } else {
                self.status = try await self.runtime.startLocalCore()
                self.notify("本地代理监听已启动")
            }
            await self.refreshAll(fullSnapshot: true)
        }
    }

    public func setSystemProxy(_ enabled: Bool) async {
        await performBusy {
            self.status = try await self.runtime.setSystemProxy(enabled: enabled)
            self.notify(enabled ? "已开启系统代理" : "已关闭系统代理并恢复原设置")
            await self.refreshAll(fullSnapshot: true)
        }
    }

    public func setTUN(_ enabled: Bool) async {
        await performBusy {
            if enabled {
                self.status = try await self.runtime.startTUN()
                self.notify("虚拟网卡 (TUN) 已开启")
            } else {
                self.status = try await self.runtime.stopCore()
                if self.profile.isConfigured {
                    self.status = try await self.runtime.startLocalCore()
                }
                self.notify("已关闭虚拟网卡")
            }
            await self.refreshAll(fullSnapshot: true)
        }
    }

    public func setMode(_ mode: RoutingMode) async {
        do {
            profile = try await runtime.profileStore.setMode(mode)
            if let client = await runtime.activeClient() {
                try await client.setMode(mode)
            }
            await refreshAll(fullSnapshot: false)
        } catch {
            notify(error.localizedDescription, isError: true)
        }
    }

    public func selectNode(_ name: String, inGroup group: String = "GLOBAL") async {
        do {
            if !status.running {
                _ = try await runtime.startLocalCore()
            }
            if let client = await runtime.activeClient() {
                try await client.selectProxy(group: group, name: name)
                await refreshAll(fullSnapshot: true)
                notify("已切换出口至 \(name)")
            } else {
                notify("已记录所选节点 \(name)")
            }
        } catch {
            notify(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Probes

    public func measureDelay(for node: ProxyNode) async {
        guard !node.isPolicy || node.name == "AUTO" else { return }
        testingNodes.insert(node.id)
        defer { testingNodes.remove(node.id) }

        do {
            if !status.running {
                _ = try await runtime.startLocalCore()
                await refreshAll(fullSnapshot: true)
            }
            guard let client = await runtime.activeClient() else {
                nodeDelays[node.id] = DelayMeasurement(error: "未连接内核")
                return
            }
            let result = await client.measureDelay(
                name: node.name,
                provider: node.isPolicy ? nil : node.provider,
                service: probeService,
                timeoutMs: probeTimeoutMs
            )
            var merged = result
            merged.mbps = nodeDelays[node.id]?.mbps
            nodeDelays[node.id] = merged
        } catch {
            nodeDelays[node.id] = DelayMeasurement(error: error.localizedDescription)
        }
    }

    public func measureAllDelays() async {
        guard !isBatchProbing else { return }
        isBatchProbing = true
        defer { isBatchProbing = false }

        let targets = selectableNodes.filter { !$0.isPolicy }
        guard !targets.isEmpty else {
            notify("当前没有可测延迟的节点", isError: true)
            return
        }
        await ProbeQueue.run(items: targets, concurrency: probeConcurrency) { [weak self] node in
            await self?.measureDelay(for: node)
        }
        notify("已完成 \(targets.count) 个节点的延迟检测")
    }

    public func measureAllBandwidth() async {
        guard !isBatchProbing else { return }
        isBatchProbing = true
        defer { isBatchProbing = false }

        let targets = selectableNodes.filter { !$0.isPolicy }
        guard !targets.isEmpty else { return }
        do {
            if !status.running {
                _ = try await runtime.startLocalCore()
                await refreshAll(fullSnapshot: true)
            }
            guard let client = await runtime.activeClient() else { return }
            for node in targets {
                testingNodes.insert(node.id)
                do {
                    let mbps = try await client.measureDownloadSpeed(nodeName: node.name)
                    var existing = nodeDelays[node.id] ?? DelayMeasurement()
                    existing.mbps = mbps
                    existing.error = nil
                    nodeDelays[node.id] = existing
                } catch {
                    var existing = nodeDelays[node.id] ?? DelayMeasurement()
                    existing.error = "测速失败"
                    nodeDelays[node.id] = existing
                }
                testingNodes.remove(node.id)
            }
            notify("全部节点带宽测速完成")
        } catch {
            notify(error.localizedDescription, isError: true)
        }
    }

    public func probeWebsite(_ host: String) async {
        guard let idx = websites.firstIndex(where: { $0.host == host }) else { return }
        websites[idx].isTesting = true
        defer { websites[idx].isTesting = false }

        do {
            if !status.running {
                _ = try await runtime.startLocalCore()
                await refreshAll(fullSnapshot: true)
            }
            guard let client = await runtime.activeClient() else {
                websites[idx].error = "内核未运行"
                return
            }
            let result = try await client.probeWebsite(host: host, localProxyPort: status.effectiveHTTPPort)
            websites[idx].latencyMs = result.ms
            websites[idx].httpStatus = result.status
            websites[idx].error = result.status >= 400 ? "HTTP \(result.status)" : nil
        } catch {
            websites[idx].error = "失败"
        }
    }

    public func probeAllWebsites() async {
        let hosts = websites.map(\.host)
        await ProbeQueue.run(items: hosts, concurrency: probeConcurrency) { [weak self] host in
            await self?.probeWebsite(host)
        }
    }

    public func detectExitIP() async {
        do {
            if !status.running {
                _ = try await runtime.startLocalCore()
                await refreshAll(fullSnapshot: true)
            }
            guard let client = await runtime.activeClient() else {
                notify("代理内核未启动", isError: true)
                return
            }
            let ip = try await client.fetchExitIP(localProxyPort: status.effectiveHTTPPort)
            networkDetails.exitIP = ip
            notify("当前出口 IP：\(ip)")
        } catch {
            notify("出口 IP 检测失败：\(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Profile Mutations

    public func mutateProfile(_ action: () async throws -> ProfileSummary, successMessage: String? = nil) async {
        do {
            profile = try await action()
            try? await runtime.reloadIfRunning()
            await refreshAll(fullSnapshot: true)
            if let successMessage {
                notify(successMessage)
            }
        } catch {
            notify(error.localizedDescription, isError: true)
        }
    }

    public func refreshSubscription(name: String) async {
        guard !refreshingProviders.contains(name) else { return }
        do {
            try await fetchSubscription(name: name)
            notify("订阅「\(name)」已刷新")
        } catch {
            notify("刷新「\(name)」失败：\(error.localizedDescription)", isError: true)
        }
    }

    func fetchSubscription(name: String, reloadConfiguration: Bool = false) async throws {
        let needsReload = reloadConfiguration || subscriptionErrors[name] != nil
        refreshingProviders.insert(name)
        subscriptionErrors[name] = nil
        defer { refreshingProviders.remove(name) }
        do {
            if needsReload { try await runtime.reloadIfRunning() }
            if let client = await runtime.activeClient() {
                try await client.refreshProvider(name: name)
                await refreshAll(fullSnapshot: true)
            } else if let provider = profile.providers.first(where: { $0.name == name }),
                      let urlString = provider.url,
                      let url = URL(string: urlString)
            {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let text = String(data: data, encoding: .utf8)
                else {
                    throw ProfileStoreError.ioError("远端订阅响应无效。")
                }
                let yamlContent: String
                if ShareLinkParser.looksLikeShareLinks(text) {
                    let nodes = try ShareLinkParser.parseBundle(text)
                    yamlContent = SimpleYAML.emit(.object(["proxies": .array(nodes)]))
                } else {
                    guard let proxies = try SimpleYAML.parse(text)["proxies"]?.arrayValue, !proxies.isEmpty else {
                        throw ProfileStoreError.invalidProfile("订阅内容中没有节点，请检查订阅地址。")
                    }
                    yamlContent = text
                }
                try await runtime.profileStore.saveProviderPayload(name: name, yamlContent: yamlContent)
                await refreshAll(fullSnapshot: true)
            } else {
                throw ProfileStoreError.missingResource("找不到可刷新的远程订阅。")
            }
        } catch {
            subscriptionErrors[name] = error.localizedDescription
            throw error
        }
    }

    public func notify(_ message: String, isError: Bool = false) {
        toast = ToastMessage(text: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 3.8 : 2.4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func performBusy(_ work: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            notify(error.localizedDescription, isError: true)
        }
    }
}
