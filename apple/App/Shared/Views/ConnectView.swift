import Charts
import SwiftUI
import XeylrouteCore

public struct ConnectView: View {
    @Environment(AppState.self) private var appState
    let requestEnableTUN: () -> Void

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                captureBannerIfNeeded
                telemetryKPIBar

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            defaultNodeSection
                            trafficChartCard
                        }
                        .frame(maxWidth: .infinity)

                        VStack(spacing: 16) {
                            if appState.runtime.supportsProcessRouting {
                                appExitsSection
                            }
                            subscriptionCard
                            activeConnectionsChartCard
                        }
                        .frame(maxWidth: 420)
                    }

                    VStack(spacing: 16) {
                        defaultNodeSection
                        if appState.runtime.supportsProcessRouting {
                            appExitsSection
                        }
                        subscriptionCard
                        trafficChartCard
                        activeConnectionsChartCard
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("连接")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                StatusPill(
                    text: appState.statusBadgeTitle,
                    tint: (appState.status.systemProxyEnabled || appState.status.tunEnabled) ? .green : (appState.status.running ? .orange : .secondary)
                )
                Button {
                    Task { await appState.toggleLocalCore() }
                } label: {
                    Label(
                        appState.status.running ? "停止内核" : "启动监听",
                        systemImage: appState.status.running ? "stop.circle" : "play.circle.fill"
                    )
                }
                .disabled(appState.isBusy)
            }
        }
    }

    @ViewBuilder
    private var captureBannerIfNeeded: some View {
        if !appState.status.systemProxyEnabled && !appState.status.tunEnabled {
            NativeCard {
                HStack(spacing: 12) {
                    Image(systemName: "shield.slash")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.status.configured ? "尚未接管系统流量" : "还没有可用的节点或订阅")
                            .font(.subheadline.weight(.semibold))
                        Text(appState.status.configured
                             ? (appState.runtime.supportsSystemProxy
                                ? "开启系统代理或虚拟网卡后，应用将按当前路由模式连接。"
                                : "开启 VPN 隧道后，设备网络流量将按当前规则接管。")
                             : "前往「订阅管理」粘贴 HTTPS 订阅或节点分享链接即可开始使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if appState.status.configured {
                        Button(appState.runtime.supportsSystemProxy ? "开启系统代理" : "开启 VPN") {
                            if appState.runtime.supportsSystemProxy {
                                Task { await appState.setSystemProxy(true) }
                            } else {
                                requestEnableTUN()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button("导入订阅") {
                            appState.selectedDestination = .subscriptions
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var telemetryKPIBar: some View {
        NativeCard(padding: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                kpiCell(value: TrafficTracker.formatRate(appState.currentDownRate), label: "实时下载", dotColor: .blue)
                kpiCell(value: TrafficTracker.formatRate(appState.currentUpRate), label: "实时上传", dotColor: .teal)
                kpiCell(value: formatDuration(appState.elapsedSeconds), label: "会话时长", dotColor: nil)
                kpiCell(value: TrafficTracker.formatBytes(appState.totalTrafficBytes), label: "已接管流量", dotColor: nil)
                kpiCell(value: "\(appState.activeRuleCount) 条", label: "生效规则", dotColor: nil)
            }
        }
    }

    private func kpiCell(value: String, label: String, dotColor: Color?) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                if let dotColor {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var defaultNodeSection: some View {
        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let quickNodes = appState.selectableNodes.filter { node in
            query.isEmpty || node.name.lowercased().contains(query) || node.type.lowercased().contains(query)
        }
        let activeName = appState.currentGlobalExit
        let activeNode = appState.selectableNodes.first { $0.name == activeName }

        return VStack(alignment: .leading, spacing: 8) {
            SectionHeaderBar("默认节点") {
                Button("全部节点 ›") {
                    appState.selectedDestination = .nodes
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }

            NativeCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        CountryBadge(nodeName: activeName, isPolicy: activeNode?.isPolicy ?? false)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(activeName)
                                    .font(.headline)
                                    .lineLimit(1)
                                if let type = activeNode?.type {
                                    StatusPill(text: type, tint: .blue)
                                }
                            }
                            Text(appState.profile.subscriptionScope.map { "当前订阅：\($0)" } ?? "独立节点 / 全局出口")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let activeNode {
                            LatencyBadge(
                                measurement: appState.nodeDelays[activeNode.id],
                                isTesting: appState.testingNodes.contains(activeNode.id)
                            )
                            Button("重测") {
                                Task { await appState.measureDelay(for: activeNode) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 8)], spacing: 8) {
                        ForEach(quickNodes.prefix(6)) { node in
                            let selected = node.name == activeName
                            Button {
                                Task { await appState.selectNode(node.name) }
                            } label: {
                                HStack(spacing: 8) {
                                    CountryBadge(nodeName: node.name, isPolicy: node.isPolicy)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(node.name)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        Text(node.currentSelection ?? node.type)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    LatencyBadge(
                                        measurement: appState.nodeDelays[node.id],
                                        isTesting: appState.testingNodes.contains(node.id)
                                    )
                                }
                                .padding(9)
                                .background(
                                    selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        Text(appState.snapshot?.proxies["AUTO"]?.now.map { "自动优选推荐：\($0)" } ?? "自动优选就绪")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("切换 AUTO ›") {
                            Task { await appState.selectNode("AUTO") }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    private var appExitsSection: some View {
        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let apps = appState.groupedApps.filter { app in
            query.isEmpty || app.name.lowercased().contains(query) || app.primaryPath.lowercased().contains(query)
        }

        return VStack(alignment: .leading, spacing: 8) {
            SectionHeaderBar("应用出口") {
                Button("规则管理 ›") {
                    appState.selectedDestination = .split
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }

            NativeCard(padding: 0) {
                if apps.isEmpty {
                    Text("暂无可显示的运行中应用")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(apps.prefix(5).enumerated()), id: \.element.id) { idx, app in
                            let currentExit = exitForApp(app)
                            HStack(spacing: 10) {
                                AppIconThumbnail(path: app.bundlePath ?? app.primaryPath)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(app.instanceCount) 个进程")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu {
                                    Button("按默认规则") {
                                        Task {
                                            await appState.mutateProfile({
                                                try await appState.runtime.profileStore.setProgramExits(paths: app.paths, exit: nil)
                                            }, successMessage: "已移除「\(app.name)」的专用出口")
                                        }
                                    }
                                    Divider()
                                    ForEach(appState.profile.exits, id: \.self) { exit in
                                        Button(exit) {
                                            Task {
                                                await appState.mutateProfile({
                                                    try await appState.runtime.profileStore.setProgramExits(paths: app.paths, exit: exit)
                                                }, successMessage: "已将「\(app.name)」出口设为 \(exit)")
                                            }
                                        }
                                    }
                                } label: {
                                    StatusPill(text: currentExit ?? "默认规则", tint: currentExit == nil ? .secondary : .blue)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                            if idx < min(apps.count, 5) - 1 {
                                Divider().padding(.leading, 50)
                            }
                        }
                    }
                }
            }
        }
    }

    private var subscriptionCard: some View {
        let activeProvider = appState.profile.providers.first { $0.name == appState.profile.subscriptionScope }
            ?? appState.profile.providers.first

        return NativeCard {
            if let provider = activeProvider {
                let live = appState.snapshot?.providers[provider.name]
                let usage = live?.usage ?? provider.usage
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: provider.isRemote ? "icloud.and.arrow.down.fill" : "doc.text.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.name)
                                .font(.subheadline.weight(.semibold))
                            Text("\(live?.nodes.count ?? provider.nodes.count) 个节点")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("刷新") {
                            Task { await appState.refreshSubscription(name: provider.name) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    if let usage, usage.total > 0 {
                        ProgressView(value: usage.progress)
                            .tint(.blue)
                        HStack {
                            Text("已用 \(TrafficTracker.formatBytes(usage.used)) / \(TrafficTracker.formatBytes(usage.total))")
                            Spacer()
                            Text("\(Int((usage.progress * 100).rounded()))%")
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("独立节点 (\(appState.profile.standaloneNodes.count))")
                            .font(.subheadline.weight(.semibold))
                        Text("可在「订阅管理」导入远端订阅或 YAML 文件")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var trafficChartCard: some View {
        NativeCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("已接管流量波形")
                        .font(.subheadline.weight(.semibold))
                    StatusPill(text: appState.profile.mode.fullTitle, tint: .secondary)
                    Spacer()
                    HStack(spacing: 10) {
                        Label("下载", systemImage: "circle.fill").foregroundStyle(.blue)
                        Label("上传", systemImage: "circle.fill").foregroundStyle(.teal)
                    }
                    .font(.caption2)
                }

                ZStack {
                    Chart(appState.trafficTracker.samples) { sample in
                        AreaMark(
                            x: .value("时间", sample.id),
                            y: .value("下载", sample.downloadBytesPerSec / 1024.0)
                        )
                        .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.28), .blue.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("时间", sample.id),
                            y: .value("下载", sample.downloadBytesPerSec / 1024.0)
                        )
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("时间", sample.id),
                            y: .value("上传", sample.uploadBytesPerSec / 1024.0)
                        )
                        .foregroundStyle(.teal)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .trailing) { val in
                            AxisGridLine()
                            AxisValueLabel {
                                if let kb = val.as(Double.self) {
                                    Text(TrafficTracker.formatRate(kb * 1024.0))
                                        .font(.caption2.monospacedDigit())
                                }
                            }
                        }
                    }
                    .frame(height: 150)

                    if appState.trafficTracker.samples.isEmpty {
                        VStack(spacing: 4) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                            Text(appState.status.running ? "正在采集实时流量…" : "启动监听后显示实时流量波形")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    let peak = appState.trafficTracker.samples.map(\.downloadBytesPerSec).max() ?? 0
                    Text("峰值下载 \(TrafficTracker.formatRate(peak))")
                    Spacer()
                    Text("127.0.0.1:\(appState.profile.mixedPort > 0 ? appState.profile.mixedPort : appState.profile.httpPort)")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var activeConnectionsChartCard: some View {
        NativeCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("活跃连接数")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    let current = appState.snapshot?.connections?.activeCount ?? 0
                    Text("当前 \(current) 个")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ZStack {
                    Chart(appState.trafficTracker.samples) { sample in
                        BarMark(
                            x: .value("采样", sample.id),
                            y: .value("连接", sample.activeConnections)
                        )
                        .foregroundStyle(.blue.gradient)
                        .cornerRadius(2)
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 100)

                    if appState.trafficTracker.samples.isEmpty {
                        Text(appState.status.running ? "等待连接采样…" : "未启动内核")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func exitForApp(_ app: GroupedRunningApp) -> String? {
        let targets = Set(app.paths.map { RunningAppGrouper.normalizePath($0) })
        return appState.profile.rules.first { rule in
            rule.enabled && rule.kind == "PROCESS-PATH" && targets.contains(RunningAppGrouper.normalizePath(rule.payload))
        }?.exit
    }
}
