import SwiftUI
import XeylrouteCore

public struct RootView: View {
    @Environment(AppState.self) private var appState
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var showTunConfirm = false

    public init() {}

    public var body: some View {
        @Bindable var state = appState

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
                        .frame(width: 8, height: 8)
                    Text(toast.text)
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
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
        @Bindable var state = appState

        return NavigationSplitView {
            VStack(spacing: 0) {
                sidebarControlHeader
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                List(selection: Binding<AppDestination?>(
                    get: { appState.selectedDestination },
                    set: { if let v = $0 { appState.selectedDestination = v } }
                )) {
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
                }
                .listStyle(.sidebar)

                sidebarLiveFooter
                    .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 224, ideal: 242, max: 280)
        } detail: {
            detailContent(for: appState.selectedDestination)
                .searchable(text: $state.searchText, placement: .toolbar, prompt: searchPrompt(for: appState.selectedDestination))
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - iPhone Native Tab Shell

    #if os(iOS)
    private var iOSCompactTabShell: some View {
        @Bindable var state = appState

        return TabView(selection: $state.selectedDestination) {
            NavigationStack {
                ConnectView(requestEnableTUN: { showTunConfirm = true })
            }
            .tabItem { Label(AppDestination.connect.shortTitle, systemImage: AppDestination.connect.systemImage) }
            .tag(AppDestination.connect)

            NavigationStack {
                NodesView()
            }
            .tabItem { Label(AppDestination.nodes.shortTitle, systemImage: AppDestination.nodes.systemImage) }
            .tag(AppDestination.nodes)

            NavigationStack {
                SplitRoutingView()
            }
            .tabItem { Label(AppDestination.split.shortTitle, systemImage: AppDestination.split.systemImage) }
            .tag(AppDestination.split)

            NavigationStack {
                SubscriptionsView()
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

    private var sidebarControlHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 30, height: 30)
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Xeylroute")
                        .font(.headline)
                    Text("\(appState.profile.mode.fullTitle) · \(appState.statusBadgeTitle)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

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

            HStack(spacing: 8) {
                if appState.runtime.supportsSystemProxy {
                    quickToggleTile(
                        title: "系统代理",
                        icon: "globe",
                        isOn: Binding(
                            get: { appState.status.systemProxyEnabled },
                            set: { on in Task { await appState.setSystemProxy(on) } }
                        )
                    )
                }
                quickToggleTile(
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
            .disabled(appState.isBusy)
        }
    }

    private func quickToggleTile(title: String, icon: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func navRow(_ dest: AppDestination, badge: Int? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: dest.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(dest.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(dest.title)
            Spacer()
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .tag(dest)
    }

    private var sidebarLiveFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appState.selectedDestination != .connect {
                HStack {
                    Text("实时流量")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("↑ \(TrafficTracker.formatRate(appState.currentUpRate))")
                            .foregroundStyle(.teal)
                        Text("↓ \(TrafficTracker.formatRate(appState.currentDownRate))")
                            .foregroundStyle(.primary)
                    }
                    .font(.caption2.monospacedDigit().weight(.medium))
                }
                Divider()
            }
            HStack {
                Circle()
                    .fill(appState.status.running ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(appState.status.coreVersionLabel)
                    .lineLimit(1)
                Spacer()
                if let mem = appState.snapshot?.connections?.memoryBytes, mem > 0 {
                    Text(TrafficTracker.formatBytes(Int64(mem)))
                } else {
                    Text(appState.status.running ? "运行中" : "已停止")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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

    private func searchPrompt(for destination: AppDestination) -> String {
        switch destination {
        case .connect: return "搜索节点或应用"
        case .nodes: return "搜索节点、分组或网站"
        case .split: return "搜索分流规则或程序"
        case .logs: return "搜索应用、目标地址或出口"
        case .subscriptions: return "搜索订阅或独立节点"
        case .settings: return "搜索设置项"
        }
    }
}

#if os(iOS)
private struct iOSMoreHubView: View {
    var body: some View {
        List {
            NavigationLink {
                LogsView()
            } label: {
                Label("连接记录与活动连接", systemImage: AppDestination.logs.systemImage)
            }
            NavigationLink {
                SettingsView()
            } label: {
                Label("网络与设置", systemImage: AppDestination.settings.systemImage)
            }
        }
        .navigationTitle("更多")
    }
}
#endif
