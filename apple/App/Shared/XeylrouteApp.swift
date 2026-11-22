import SwiftUI
import XeylrouteCore

@main
struct XeylrouteAppleApp: App {
    @State private var appState = AppState.makeDefault()

    var body: some Scene {
        #if os(macOS)
        WindowGroup("Xeylroute") {
            RootView()
                .environment(appState)
                .preferredColorScheme(appState.appearance.colorScheme)
                .frame(minWidth: 860, minHeight: 580)
                .task {
                    await appState.bootstrap()
                }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarPopoverView()
                .environment(appState)
                .preferredColorScheme(appState.appearance.colorScheme)
        } label: {
            Label {
                Text("Xeylroute")
            } icon: {
                Image(systemName: appState.status.systemProxyEnabled || appState.status.tunEnabled
                    ? "network.badge.shield.half.filled"
                    : "network")
            }
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup("Xeylroute") {
            RootView()
                .environment(appState)
                .preferredColorScheme(appState.appearance.colorScheme)
                .task {
                    await appState.bootstrap()
                }
        }
        #endif
    }
}

#if os(macOS)
struct MenuBarPopoverView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Xeylroute")
                        .font(.headline)
                    Text(appState.statusBadgeTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(appState.status.running ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
            }

            Picker("代理模式", selection: Binding(
                get: { appState.profile.mode },
                set: { mode in Task { await appState.setMode(mode) } }
            )) {
                ForEach(RoutingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(spacing: 8) {
                Toggle("系统代理", isOn: Binding(
                    get: { appState.status.systemProxyEnabled },
                    set: { on in Task { await appState.setSystemProxy(on) } }
                ))
                Toggle("虚拟网卡 (TUN)", isOn: Binding(
                    get: { appState.status.tunEnabled },
                    set: { on in Task { await appState.setTUN(on) } }
                ))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(appState.isBusy)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("快速切换默认节点")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(appState.selectableNodes.prefix(6)) { node in
                    Button {
                        Task { await appState.selectNode(node.name) }
                    } label: {
                        HStack {
                            Image(systemName: appState.currentGlobalExit == node.name ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(appState.currentGlobalExit == node.name ? Color.accentColor : Color.secondary)
                            Text(node.name)
                                .lineLimit(1)
                            Spacer()
                            LatencyBadge(
                                measurement: appState.nodeDelays[node.id],
                                isTesting: appState.testingNodes.contains(node.id)
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                }
            }

            Divider()

            HStack {
                Text("↓ \(TrafficTracker.formatRate(appState.currentDownRate))")
                Text("↑ \(TrafficTracker.formatRate(appState.currentUpRate))")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption.monospacedDigit())

            HStack {
                Button("打开主窗口") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "Xeylroute")
                    }
                }
                Spacer()
                Button("退出") {
                    Task {
                        await appState.shutdown()
                        NSApp.terminate(nil)
                    }
                }
                .foregroundStyle(.red)
            }
        }
        .padding(18)
        .frame(width: 300)
    }
}
#endif
