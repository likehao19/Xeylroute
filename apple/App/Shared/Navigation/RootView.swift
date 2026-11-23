import SwiftUI
import XeylrouteCore

public struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var showTunConfirm = false

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            #if os(iOS)
            if sizeClass == .compact {
                iOSCompactTabShell
            } else {
                splitViewShell
            }
            #else
            splitViewShell
            #endif

            if let toast = appState.toast {
                HStack(spacing: 8) {
                    Circle()
                        .fill(toast.isError ? Color.red : Color.green)
                        .frame(width: 7, height: 7)
                    Text(toast.text)
                        .font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .floatingGlass(in: Capsule())
                .padding(20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: appState.toast)
        .alert("开启虚拟网卡 (TUN)", isPresented: $showTunConfirm) {
            Button("取消", role: .cancel) {}
            Button("继续开启") {
                Task { await appState.setTUN(true) }
            }
        } message: {
            #if os(macOS)
            Text("虚拟网卡 (TUN) 将接管系统受支持流量，需要 macOS 管理员授权启动 TUN 后台，主窗口继续以普通权限运行。")
            #else
            Text("开启后将通过 iOS 系统 VPN 隧道 (NetworkExtension) 接管设备流量。")
            #endif
        }
    }

    // MARK: - macOS & iPadOS Native Split View

    private var splitViewShell: some View {
        NavigationSplitView {
            #if os(macOS)
            sidebarNavigation
                .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
                .navigationTitle("Xeylroute")
                .navigationSplitViewColumnWidth(min: 175, ideal: 192, max: 226)
            #else
            VStack(spacing: 0) {
                sidebarControlHeader
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                sidebarNavigation
                sidebarLiveFooter
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .padding(.top, 4)
            }
            .navigationSplitViewColumnWidth(min: 224, ideal: 238, max: 272)
            #endif
        } detail: {
            StageCanvas {
                #if os(macOS)
                GeometryReader { area in
                    detailContent(for: appState.selectedDestination)
                        .frame(width: area.size.width, height: area.size.height, alignment: .topLeading)
                }
                #else
                detailContent(for: appState.selectedDestination)
                #endif
            }
            #if os(macOS)
            .navigationTitle(appState.selectedDestination.desktopTitle)
            #endif
        }
        .navigationSplitViewStyle(.balanced)
        #if os(macOS)
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        #endif
    }

    private var sidebarNavigation: some View {
        List(selection: Binding<AppDestination?>(
            get: { appState.selectedDestination },
            set: { if let v = $0 { appState.selectedDestination = v } }
        )) {
            #if os(macOS)
            Section("网络") {
                navRow(.connect)
                navRow(.nodes, badge: appState.proxyServers.count)
                navRow(.logs)
            }
            Section("配置") {
                navRow(.subscriptions, badge: appState.profile.providers.count)
                navRow(.split, badge: appState.activeRuleCount)
                navRow(.settings)
            }
            Section("连接控制") {
                macNetworkControls
                macSidebarStatus
                    .padding(.vertical, 5)
                    .selectionDisabled()
            }
            #else
            Section("代理与路由") {
                navRow(.connect)
                navRow(.nodes, badge: appState.selectableNodes.filter { !$0.isPolicy }.count)
                navRow(.split, badge: appState.activeRuleCount)
            }
            Section("管理与诊断") {
                navRow(.logs)
                navRow(.subscriptions, badge: appState.profile.providers.count)
                navRow(.settings)
            }
            #endif
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    #if os(macOS)
    private var macNetworkControls: some View {
        Group {
            HStack {
                Label("路由模式", systemImage: "arrow.triangle.branch")
                Spacer(minLength: 4)
                Picker("路由模式", selection: Binding(
                    get: { appState.profile.mode },
                    set: { mode in Task { await appState.setMode(mode) } }
                )) {
                    ForEach(RoutingMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).buttonStyle(.borderless)
                .foregroundStyle(.primary).fixedSize()
            }
            Toggle(isOn: Binding(
                get: { appState.status.systemProxyEnabled },
                set: { on in Task { await appState.setSystemProxy(on) } }
            )) {
                Label("系统代理", systemImage: "globe").frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(isOn: Binding(
                get: { appState.status.tunEnabled },
                set: { on in
                    if on { showTunConfirm = true } else { Task { await appState.setTUN(false) } }
                }
            )) {
                Label("虚拟网卡", systemImage: "shield").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .listItemTint(.monochrome)
        .selectionDisabled()
        .disabled(appState.isBusy)
    }

    private var macSidebarStatus: some View {
        let status = HStack(spacing: 5) {
            Circle().fill(statusDotColor).frame(width: 6, height: 6)
            Text(appState.statusBadgeTitle).font(.callout.weight(.medium))
        }
        return VStack(alignment: .leading, spacing: 4) {
            if appState.status.running {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        status.fixedSize()
                        Spacer(minLength: 5)
                        Text(appState.status.coreVersionLabel.replacingOccurrences(of: "Mihomo ", with: ""))
                            .font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                    status
                }
                let down = TrafficTracker.formatRate(appState.currentDownRate)
                let up = TrafficTracker.formatRate(appState.currentUpRate)
                HStack(spacing: 10) {
                    Text("↓ \(down)").accessibilityLabel("下载速率 \(down)")
                    Text("↑ \(up)").accessibilityLabel("上传速率 \(up)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            } else {
                status
                Text(appState.status.coreVersionLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .help(appState.status.coreVersionLabel + " · " + appState.statusBadgeTitle)
    }
    #endif

    // MARK: - iPhone Native Tab Shell

    #if os(iOS)
    private var iOSCompactTabShell: some View {
        @Bindable var state = appState

        return TabView(selection: $state.selectedDestination) {
            NavigationStack {
                StageCanvas {
                    ConnectView(requestEnableTUN: { showTunConfirm = true })
                }
            }
            .tabItem { Label(AppDestination.connect.shortTitle, systemImage: AppDestination.connect.systemImage) }
            .tag(AppDestination.connect)

            NavigationStack {
                StageCanvas { NodesView() }
            }
            .tabItem { Label(AppDestination.nodes.shortTitle, systemImage: AppDestination.nodes.systemImage) }
            .tag(AppDestination.nodes)

            NavigationStack {
                StageCanvas { SplitRoutingView() }
            }
            .tabItem { Label(AppDestination.split.shortTitle, systemImage: AppDestination.split.systemImage) }
            .tag(AppDestination.split)

            NavigationStack {
                StageCanvas { SubscriptionsView() }
            }
            .tabItem { Label(AppDestination.subscriptions.shortTitle, systemImage: AppDestination.subscriptions.systemImage) }
            .tag(AppDestination.subscriptions)

            NavigationStack {
                iOSMoreHubView()
            }
            .tabItem { Label("更多", systemImage: "ellipsis.circle.fill") }
            .tag(AppDestination.settings)
        }
    }
    #endif

    // MARK: - Sidebar Subcomponents

    #if os(iOS)
    private var sidebarControlHeader: some View {
        let palette = XeylPalette(colorScheme)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image("AppBrandLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 2.5, y: 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Xeylroute")
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusDotColor)
                            .frame(width: 6, height: 6)
                        Text("\(appState.profile.mode.fullTitle) · \(appState.statusBadgeTitle)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 2)

            Picker("模式", selection: Binding(
                get: { appState.profile.mode },
                set: { mode in Task { await appState.setMode(mode) } }
            )) {
                ForEach(RoutingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Unified Dual Quick-Capture Capsule
            HStack(spacing: 0) {
                if appState.runtime.supportsSystemProxy {
                    quickCaptureCell(
                        title: "系统代理",
                        icon: "globe",
                        isOn: Binding(
                            get: { appState.status.systemProxyEnabled },
                            set: { on in Task { await appState.setSystemProxy(on) } }
                        )
                    )
                    palette.divider
                        .frame(width: 0.75)
                        .padding(.vertical, 8)
                }
                quickCaptureCell(
                    title: appState.runtime.supportsSystemProxy ? "虚拟网卡" : "VPN 隧道",
                    icon: "shield.lefthalf.filled",
                    isOn: Binding(
                        get: { appState.status.tunEnabled },
                        set: { on in
                            if on {
                                showTunConfirm = true
                            } else {
                                Task { await appState.setTUN(false) }
                            }
                        }
                    )
                )
            }
            .background(palette.cardSurface.opacity(0.78), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(palette.cardBorder, lineWidth: 0.75)
            )
            .disabled(appState.isBusy)
        }
    }

    private func quickCaptureCell(title: String, icon: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                Spacer(minLength: 4)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #endif

    @ViewBuilder
    private func navRow(_ dest: AppDestination, badge: Int? = nil) -> some View {
        #if os(macOS)
        Label {
            Text(dest.desktopTitle)
        } icon: {
            Image(systemName: dest.systemImage)
                .symbolVariant(.none)
                .foregroundColor(appState.selectedDestination == dest ? nil : .secondary)
        }
        .badge(badge ?? 0).padding(.vertical, 2).tag(dest)
        #else
        let isSelected = appState.selectedDestination == dest
        HStack(spacing: 8) {
            Image(systemName: dest.systemImage)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(dest.tint))
                .frame(width: 20, alignment: .center)
            Text(dest.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            Spacer()
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.75), in: Capsule())
            }
        }
        .padding(.vertical, 1.5)
        .tag(dest)
        #endif
    }

    #if os(iOS)
    private var sidebarLiveFooter: some View {
        let palette = XeylPalette(colorScheme)
        return VStack(alignment: .leading, spacing: 6) {
            if appState.status.running {
                HStack(alignment: .center) {
                    Text("实时流量")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("↑ \(TrafficTracker.formatRate(appState.currentUpRate))")
                            .foregroundStyle(.teal)
                        Text("↓ \(TrafficTracker.formatRate(appState.currentDownRate))")
                            .foregroundStyle(.primary)
                    }
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                }
                palette.divider.frame(height: 0.5)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6.5, height: 6.5)
                Text(appState.status.coreVersionLabel)
                    .lineLimit(1)
                Spacer()
                if let mem = appState.snapshot?.connections?.memoryBytes, mem > 0 {
                    Text(TrafficTracker.formatBytes(Int64(mem)))
                } else {
                    Text(appState.status.running ? "运行中" : "已停止")
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(palette.cardSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 0.75)
        )
    }
    #endif

    private var statusDotColor: Color {
        if appState.status.systemProxyEnabled || appState.status.tunEnabled { return .green }
        if appState.status.running { return .orange }
        return .secondary.opacity(0.45)
    }

    @ViewBuilder
    private func detailContent(for destination: AppDestination) -> some View {
        switch destination {
        case .connect:
            ConnectView(requestEnableTUN: { showTunConfirm = true })
        case .nodes:
            NodesView()
        case .split:
            SplitRoutingView()
        case .logs:
            LogsView()
        case .subscriptions:
            SubscriptionsView()
        case .settings:
            SettingsView()
        }
    }
}

#if os(iOS)
private struct iOSMoreHubView: View {
    var body: some View {
        List {
            NavigationLink {
                StageCanvas { LogsView() }
            } label: {
                Label("连接记录与活动连接", systemImage: AppDestination.logs.systemImage)
            }
            NavigationLink {
                StageCanvas { SettingsView() }
            } label: {
                Label("网络与设置", systemImage: AppDestination.settings.systemImage)
            }
        }
        .navigationTitle("更多")
    }
}
#endif
