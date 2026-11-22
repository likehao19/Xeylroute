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
                        Label("连接详情", systemImage: "info.circle")
                    }
                    .help("查看节点、订阅与应用出口")
                    .popover(isPresented: $showInspector) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("连接详情").font(.headline)
                                defaultNodeSection
                                subscriptionCard
                                appExitsSection
                            }.padding(16)
                        }.frame(width: 330, height: 430)
                    }
                }
                #endif
            }
        }
    }

    #if os(macOS)
    private var macConnectionView: some View {
        let nodes = appState.selectableNodes.filter { !$0.isPolicy }.count
        let waiting = !appState.profile.providers.isEmpty && nodes == 0 && !appState.status.running
        let ready = appState.status.configured && !waiting
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.18), lineWidth: 1)
                        Image(systemName: appState.status.systemProxyEnabled || appState.status.tunEnabled ? "checkmark.shield" : "power")
                            .font(.system(size: 24, weight: .medium))
                    }
                    .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(waiting ? "订阅等待更新" : (ready ? appState.statusBadgeTitle : "添加第一个配置"))
                            .font(.system(size: 24, weight: .semibold))
                        Text(waiting ? "获取节点后即可连接。" : (ready ? (appState.status.running ? "本机监听中" : "配置已就绪") : "使用订阅链接、节点链接或本地文件。"))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    Spacer(minLength: 8)
                    if waiting {
                        Button("查看订阅") { appState.selectedDestination = .subscriptions }
                            .buttonStyle(.bordered)
                    } else if ready {
                        Toggle("系统代理", isOn: Binding(
                            get: { appState.status.systemProxyEnabled },
                            set: { value in Task { await appState.setSystemProxy(value) } }
                        )).toggleStyle(.switch).disabled(appState.isBusy)
                    }
                }
                .foregroundStyle(.white)
                .padding(22)
                .background(
                    LinearGradient(colors: [Color(red: 0.08, green: 0.18, blue: 0.23),
                                            Color(red: 0.10, green: 0.33, blue: 0.36)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14)
                )

                if ready {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("路由模式", systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                            Picker("路由模式", selection: Binding(get: { appState.profile.mode }, set: { mode in
                                Task { await appState.setMode(mode) }
                            })) {
                                ForEach(RoutingMode.allCases) { Text($0.fullTitle).tag($0) }
                            }.labelsHidden().fixedSize()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        VStack(alignment: .leading, spacing: 7) {
                            Label("全局出口", systemImage: "network").font(.caption).foregroundStyle(.secondary)
                            Menu {
                                ForEach(appState.selectableNodes) { node in
                                    Button(node.name) { Task { await appState.selectNode(node.name) } }
                                }
                            } label: {
                                Text(appState.profile.mode == .direct ? "直连" : appState.snapshot?.proxies["GLOBAL"]?.now ?? "选择节点…").lineLimit(1)
                            }
                            .help("选择节点会启动本地监听")
                            .disabled(appState.profile.mode == .direct)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(16).macPanel()
                } else if !waiting {
                    ConnectionSourceEditor().padding(18).macPanel()
                }

                HStack(spacing: 10) {
                    overviewLink(.subscriptions, value: appState.profile.providers.count)
                    overviewLink(.nodes, value: nodes)
                    overviewLink(.split, value: appState.activeRuleCount)
                }

                if ready {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Text("网络活动").font(.headline)
                            Spacer()
                            if appState.status.running {
                                Picker("图表", selection: $showConnections) {
                                    Text("流量").tag(false)
                                    Text("连接数").tag(true)
                                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                            }
                        }
                        if appState.status.running || !appState.trafficTracker.samples.isEmpty {
                            if showConnections { connectionsPlot } else { trafficPlot }
                        } else {
                            HStack {
                                Label("启动本地监听后显示实时流量。", systemImage: "waveform.path.ecg")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("启动监听") { Task { await appState.toggleLocalCore() } }
                                    .disabled(appState.isBusy)
                            }
                        }
                    }.padding(16).macPanel()
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, 24).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func overviewLink(_ page: AppDestination, value: Int) -> some View {
        Button {
            appState.selectedDestination = page
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: page.systemImage).foregroundStyle(page.tint)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(String(value)).font(.title2.weight(.semibold)).monospacedDigit()
                    Text(page == .split ? "启用规则" : page.desktopTitle).font(.callout).foregroundStyle(.secondary)
                }
            }.padding(14).macPanel().contentShape(Rectangle())
        }.buttonStyle(.plain)
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
