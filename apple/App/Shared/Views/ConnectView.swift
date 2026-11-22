import Charts
import SwiftUI
import XeylrouteCore

public struct ConnectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
    @State private var showInspector = false
    @State private var showConnections = false
    #endif
    let requestEnableTUN: () -> Void

    public var body: some View {
        Group {
            #if os(macOS)
            macConnectionView
            #else
            dashboard
            #endif
        }
        .navigationTitle("连接")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                #if os(iOS)
                StatusPill(
                    text: appState.statusBadgeTitle,
                    tint: (appState.status.systemProxyEnabled || appState.status.tunEnabled)
                        ? .green
                        : (appState.status.running ? .orange : .secondary),
                    showDot: true
                )
                Button {
                    Task { await appState.toggleLocalCore() }
                } label: {
                    Label(
                        appState.status.running ? "停止内核" : "启动监听",
                        systemImage: appState.status.running ? "stop.fill" : "play.fill"
                    )
                }
                .disabled(appState.isBusy)
                #else
                if appState.status.configured || appState.status.running {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("连接详情", systemImage: "sidebar.right")
                    }
                    .help("显示或隐藏节点、订阅与应用出口")
                }
                #endif
            }
        }
    }

    #if os(macOS)
    private var macConnectionView: some View {
        let configured = appState.status.configured
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if configured {
                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .font(.title).foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appState.statusBadgeTitle).font(.title.bold())
                            Text(appState.status.running ? "本地监听已启动" : "开启系统代理后即可连接。")
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Toggle(isOn: Binding(
                            get: { appState.status.systemProxyEnabled },
                            set: { enabled in Task { await appState.setSystemProxy(enabled) } }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("系统代理").font(.headline)
                                Text("让遵循 Mac 系统代理设置的应用使用当前配置。")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.switch)
                        .disabled(appState.isBusy)
                        .padding(16)
                        Divider()
                        HStack {
                            Label("路由模式", systemImage: "arrow.triangle.branch")
                            Spacer()
                            Picker("路由模式", selection: Binding(
                                get: { appState.profile.mode },
                                set: { mode in Task { await appState.setMode(mode) } }
                            )) {
                                Text("按规则分流").tag(RoutingMode.rule)
                                Text("全部使用默认出口").tag(RoutingMode.global)
                                Text("全部直连").tag(RoutingMode.direct)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        .padding(16)
                        Divider()
                        HStack {
                            Label("默认出口", systemImage: "network")
                            Spacer()
                            Menu {
                                ForEach(appState.selectableNodes) { node in
                                    Button {
                                        Task { await appState.selectNode(node.name) }
                                    } label: {
                                        if node.name == appState.snapshot?.proxies["GLOBAL"]?.now {
                                            Label(node.name, systemImage: "checkmark")
                                        } else {
                                            Text(node.name)
                                        }
                                    }
                                }
                            } label: { Text(appState.profile.mode == .direct ? "直连" : (appState.snapshot?.proxies["GLOBAL"]?.now ?? "选择节点…")).lineLimit(1) }
                            .disabled(appState.profile.mode == .direct)
                            .frame(maxWidth: 220, alignment: .trailing)
                            .accessibilityLabel("切换默认出口")
                            .help(appState.status.running ? "切换默认出口" : "选择节点会启动本地监听")
                        }
                        .padding(16)
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                } else if !appState.profile.providers.isEmpty {
                    RouteSetupPanel(title: "订阅已保存，等待节点",
                                    detail: "节点就绪后即可连接。在订阅管理中可以查看获取进度，或重试失败的订阅。",
                                    source: "订阅来源", destination: "代理节点",
                                    sourceIcon: "square.stack.3d.up", destinationIcon: "network",
                                    actionTitle: "查看订阅") { appState.selectedDestination = .subscriptions }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 18) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("导入网络配置").font(.system(size: 27, weight: .semibold))
                                Text("粘贴服务商提供的链接，或打开本地配置文件。")
                                    .font(.body).foregroundStyle(.white.opacity(0.83))
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.down.on.square")
                                .font(.system(size: 35, weight: .light))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.white)
                        .padding(24)
                        .background(LinearGradient(colors: [Color(red: 0.12, green: 0.21, blue: 0.27),
                                                           Color(red: 0.15, green: 0.33, blue: 0.36)],
                                                   startPoint: .leading, endPoint: .trailing))
                        ConnectionSourceEditor().padding(24)
                    }
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
                    .padding(.top, 20)
                }
                if appState.status.running || !appState.trafficTracker.samples.isEmpty {
                    Divider()
                    HStack {
                        Text("网络活动").font(.title2.bold())
                        Spacer()
                        Picker("监控指标", selection: $showConnections) {
                            Text("流量").tag(false)
                            Text("连接数").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if showConnections { connectionsPlot } else { trafficPlot }
                }
            }
            .frame(maxWidth: configured ? 780 : 600, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .inspector(isPresented: $showInspector) {
            ScrollView {
                VStack(spacing: 20) {
                    defaultNodeSection
                    subscriptionCard
                    appExitsSection
                }
                .padding(14)
            }
            .inspectorColumnWidth(min: 270, ideal: 312, max: 380)
        }
    }
    #endif

    #if os(iOS)
    private var dashboard: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !appState.status.configured {
                    onboardingHeroCard
                } else if !appState.status.systemProxyEnabled && !appState.status.tunEnabled {
                    capturePromptBanner
                }

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
                        .frame(width: 340)
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
    }

    #endif

    // MARK: - Onboarding & Status Banners

    private var onboardingHeroCard: some View {
        NativeCard(padding: 18) {
            HStack(spacing: 16) {
                Image("AppBrandLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 Xeylroute 原生版")
                        .font(.system(size: 15, weight: .semibold))
                    Text("导入 HTTPS 订阅、节点分享链接（VLESS / VMess / Trojan / SS / Hysteria2 / TUIC）或 Clash YAML 文件即可开始代理与分流。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("导入订阅或节点…") {
                    appState.selectedDestination = .subscriptions
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var capturePromptBanner: some View {
        NativeCard(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: "globe.badge.chevron.backward")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 32, height: 32)
                    .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("尚未接管系统流量")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(appState.runtime.supportsSystemProxy
                         ? "开启系统代理或虚拟网卡后，应用流量将按当前路由模式转发。"
                         : "开启 iOS VPN 隧道后，设备网络流量将按当前规则接管。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(appState.runtime.supportsSystemProxy ? "开启系统代理" : "开启 VPN") {
                    if appState.runtime.supportsSystemProxy {
                        Task { await appState.setSystemProxy(true) }
                    } else {
                        requestEnableTUN()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    // MARK: - 5-Column KPI Telemetry Capsule

    private var telemetryKPIBar: some View {
        let palette = XeylPalette(colorScheme)
        return NativeCard(padding: 12) {
            HStack(spacing: 0) {
                kpiCell(value: TrafficTracker.formatRate(appState.currentDownRate), label: "实时下载", dotColor: .blue)
                palette.divider.frame(width: 0.75, height: 28)
                kpiCell(value: TrafficTracker.formatRate(appState.currentUpRate), label: "实时上传", dotColor: .teal)
                palette.divider.frame(width: 0.75, height: 28)
                kpiCell(value: formatDuration(appState.elapsedSeconds), label: "会话时长", dotColor: nil)
                palette.divider.frame(width: 0.75, height: 28)
                kpiCell(value: TrafficTracker.formatBytes(appState.totalTrafficBytes), label: "已接管流量", dotColor: nil)
                palette.divider.frame(width: 0.75, height: 28)
                kpiCell(value: "\(appState.activeRuleCount) 条", label: "生效分流规则", dotColor: nil)
            }
        }
    }

    private func kpiCell(value: String, label: String, dotColor: Color?) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            HStack(spacing: 4) {
                if let dotColor {
                    Circle().fill(dotColor).frame(width: 5.5, height: 5.5)
                }
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Default Node Spotlight & Quick Grid

    private var defaultNodeSection: some View {
        let activeName = appState.currentGlobalExit
        let activeNode = appState.selectableNodes.first { $0.name == activeName }

        return VStack(alignment: .leading, spacing: 8) {
            SectionHeaderBar("默认节点") {
                Button("全部节点 ›") {
                    appState.selectedDestination = .nodes
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }

            NativeCard(padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    // Hero Spotlight Row
                    HStack(spacing: 12) {
                        CountryBadge(nodeName: activeName, isPolicy: activeNode?.isPolicy ?? true, size: .large)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Text(activeName)
                                    .font(.system(size: 15.5, weight: .semibold))
                                    .lineLimit(1)
                                if let type = activeNode?.type {
                                    StatusPill(text: type, tint: .blue)
                                }
                                if let activeNode {
                                    LatencyBadge(
                                        measurement: appState.nodeDelays[activeNode.id],
                                        isTesting: appState.testingNodes.contains(activeNode.id)
                                    )
                                }
                            }
                            Text(appState.profile.subscriptionScope.map { "订阅来源：\($0)" } ?? "独立节点 / 全局出口")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let activeNode {
                            Button("重测") {
                                Task { await appState.measureDelay(for: activeNode) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    HairlineDivider(inset: 0)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 9)], spacing: 9) {
                        ForEach(appState.selectableNodes.prefix(6)) { node in
                            NodeQuickTile(
                                node: node,
                                isSelected: node.name == activeName,
                                measurement: appState.nodeDelays[node.id],
                                isTesting: appState.testingNodes.contains(node.id)
                            ) {
                                Task { await appState.selectNode(node.name) }
                            }
                        }
                    }

                    HairlineDivider(inset: 0)

                    HStack {
                        Text(appState.snapshot?.proxies["AUTO"]?.now.map { "自动优选推荐：\($0)" } ?? "自动优选就绪")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("切换 AUTO ›") {
                            Task { await appState.selectNode("AUTO") }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    // MARK: - Running Apps Quick Exits (macOS)

    private var appExitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeaderBar("应用出口") {
                Button("规则管理 ›") {
                    appState.selectedDestination = .split
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }

            NativeCard(padding: 0) {
                if appState.groupedApps.isEmpty {
                    Text("暂无可显示的运行中应用")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                } else {
                    VStack(spacing: 0) {
                        let visible = Array(appState.groupedApps.prefix(5))
                        ForEach(Array(visible.enumerated()), id: \.element.id) { idx, app in
                            let currentExit = exitForApp(app)
                            GroupedRow(
                                title: app.name,
                                subtitle: "\(app.instanceCount) 个进程",
                                leading: {
                                    AppIconThumbnail(path: app.bundlePath ?? app.primaryPath, size: 26)
                                },
                                trailing: {
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
                            )
                            if idx < visible.count - 1 {
                                HairlineDivider(inset: 54)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Subscription Summary Card

    private var subscriptionCard: some View {
        let activeProvider = appState.profile.providers.first { $0.name == appState.profile.subscriptionScope }
            ?? appState.profile.providers.first

        return NativeCard(padding: 15) {
            if let provider = activeProvider {
                let live = appState.snapshot?.providers[provider.name]
                let usage = live?.usage ?? provider.usage
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: provider.isRemote ? "icloud.and.arrow.down.fill" : "doc.text.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.blue)
                            .frame(width: 30, height: 30)
                            .background(Color.blue.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.name)
                                .font(.system(size: 13.5, weight: .semibold))
                                .lineLimit(1)
                            Text("\(live?.nodes.count ?? provider.nodes.count) 个节点")
                                .font(.system(size: 11.5))
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
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.orange)
                        .frame(width: 30, height: 30)
                        .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("独立节点 (\(appState.profile.standaloneNodes.count))")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("前往「订阅管理」导入远端订阅或 YAML")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Live Traffic & Active Connections Charts

    #if os(iOS)
    private var trafficChartCard: some View {
        NativeCard(padding: 16) { trafficPlot }
    }
    #endif

    private var trafficPlot: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(iOS)
            HStack {
                Text("已接管流量波形")
                    .font(.system(size: 13.5, weight: .semibold))
                StatusPill(text: appState.profile.mode.fullTitle, tint: .secondary)
                Spacer()
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Circle().fill(.blue).frame(width: 6, height: 6)
                        Text("下载")
                    }
                    HStack(spacing: 4) {
                        Circle().fill(.teal).frame(width: 6, height: 6)
                        Text("上传")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            #else
            HStack(alignment: .bottom, spacing: 32) {
                trafficReading("下载", icon: "arrow.down", rate: appState.currentDownRate, tint: .blue)
                trafficReading("上传", icon: "arrow.up", rate: appState.currentUpRate, tint: .teal)
                Spacer()
                Label(formatDuration(appState.elapsedSeconds), systemImage: "clock")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("会话时长")
            }
            #endif

            ZStack {
                Chart(appState.trafficTracker.samples) { sample in
                    AreaMark(
                        x: .value("时间", sample.id),
                        y: .value("下载", sample.downloadBytesPerSec / 1024.0)
                    )
                    .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.26), .blue.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", sample.id),
                        y: .value("下载", sample.downloadBytesPerSec / 1024.0),
                        series: .value("方向", "下载")
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", sample.id),
                        y: .value("上传", sample.uploadBytesPerSec / 1024.0),
                        series: .value("方向", "上传")
                    )
                    .foregroundStyle(.teal)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { val in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(.secondary.opacity(0.25))
                        AxisValueLabel {
                            if let kb = val.as(Double.self) {
                                Text(TrafficTracker.formatRate(kb * 1024.0))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: 152)

                if appState.trafficTracker.samples.isEmpty {
                    VStack(spacing: 5) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text(appState.status.running ? "正在采集实时流量…" : "启动监听后显示实时流量波形")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HairlineDivider(inset: 0)

            HStack {
                let peak = appState.trafficTracker.samples.map(\.downloadBytesPerSec).max() ?? 0
                #if os(macOS)
                Text("累计 \(TrafficTracker.formatBytes(appState.totalTrafficBytes))")
                Text("\(appState.activeRuleCount) 条规则")
                #endif
                Text("峰值下载 \(TrafficTracker.formatRate(peak))")
                Spacer()
                Text("127.0.0.1:\(String(appState.profile.mixedPort > 0 ? appState.profile.mixedPort : appState.profile.httpPort))")
            }
            .font(.system(size: 11, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    #if os(macOS)
    private func trafficReading(_ title: String, icon: String, rate: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            .font(.caption)
            Text(TrafficTracker.formatRate(rate))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
    }
    #endif

    #if os(iOS)
    private var activeConnectionsChartCard: some View {
        NativeCard(padding: 16) { connectionsPlot }
    }
    #endif

    private var connectionsPlot: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("活跃连接数")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                let current = appState.snapshot?.connections?.activeCount ?? 0
                Text("当前 \(current) 个")
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            ZStack {
                Chart(appState.trafficTracker.samples) { sample in
                    BarMark(
                        x: .value("采样", sample.id),
                        y: .value("连接", sample.activeConnections)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.75))
                    .cornerRadius(2)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 106)

                if appState.trafficTracker.samples.isEmpty {
                    Text(appState.status.running ? "等待连接采样…" : "内核未运行")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            HairlineDivider(inset: 0)

            HStack {
                Text("较早 → 最新")
                Spacer()
                Text("最近 60 秒")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
    }

    private func exitForApp(_ app: GroupedRunningApp) -> String? {
        let targets = Set(app.paths.map { RunningAppGrouper.normalizePath($0) })
        return appState.profile.rules.first { rule in
            rule.enabled && rule.kind == "PROCESS-PATH" && targets.contains(RunningAppGrouper.normalizePath(rule.payload))
        }?.exit
    }
}

// MARK: - Node Quick Tile (with smooth macOS hover + crisp selection)

public struct NodeQuickTile: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    let node: ProxyNode
    let isSelected: Bool
    let measurement: DelayMeasurement?
    let isTesting: Bool
    let action: () -> Void

    public var body: some View {
        let palette = XeylPalette(colorScheme)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Button(action: action) {
            HStack(spacing: 9) {
                CountryBadge(nodeName: node.name, isPolicy: node.isPolicy, size: .compact)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(node.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(node.currentSelection ?? node.type)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                LatencyBadge(measurement: measurement, isTesting: isTesting)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                isSelected
                    ? palette.selectedFill
                    : (isHovering ? palette.tileHover : palette.tileSurface),
                in: shape
            )
            .overlay(
                shape.strokeBorder(
                    isSelected ? palette.selectedBorder : palette.tileBorder,
                    lineWidth: isSelected ? 1.2 : 0.75
                )
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
