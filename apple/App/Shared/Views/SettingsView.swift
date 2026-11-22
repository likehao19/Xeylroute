import SwiftUI
import XeylrouteCore

public struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    @State private var mixedPortText = "7890"
    @State private var httpPortText = "0"
    @State private var socksPortText = "0"
    @State private var coreLogSheetText: String?

    public var body: some View {
        @Bindable var state = appState

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Appearance
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeaderBar("外观")
                    NativeCard(padding: 0) {
                        GroupedRow(title: "外观模式", subtitle: "自动跟随 macOS / iOS 系统浅色或深色主题") {
                            settingsIcon("circle.lefthalf.filled", tint: .blue)
                        } trailing: {
                            Picker("外观模式", selection: $state.appearance) {
                                ForEach(AppearanceMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 220)
                        }
                    }
                }

                // Network Capture
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeaderBar("网络接管")
                    NativeCard(padding: 0) {
                        VStack(spacing: 0) {
                            if appState.runtime.supportsSystemProxy {
                                GroupedRow(
                                    title: "macOS 系统代理",
                                    subtitle: "开启后自动接管活动网络服务的 HTTP/HTTPS/SOCKS 代理，关闭或异常退出时自动恢复原值。"
                                ) {
                                    settingsIcon("globe", tint: .blue)
                                } trailing: {
                                    Toggle("", isOn: Binding(
                                        get: { appState.status.systemProxyEnabled },
                                        set: { on in Task { await appState.setSystemProxy(on) } }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .disabled(appState.isBusy)
                                }
                                HairlineDivider(inset: 56)
                            }

                            GroupedRow(
                                title: appState.runtime.supportsSystemProxy ? "虚拟网卡 (TUN)" : "iOS VPN 隧道",
                                subtitle: appState.runtime.supportsSystemProxy
                                    ? "使用 Mixed 协议栈接管系统全部受支持流量，并拦截进入网卡的 53 端口 DNS 请求。"
                                    : "通过系统 NetworkExtension (NEPacketTunnelProvider) 接管设备流量。"
                            ) {
                                settingsIcon("shield.lefthalf.filled", tint: .indigo)
                            } trailing: {
                                Toggle("", isOn: Binding(
                                    get: { appState.status.tunEnabled },
                                    set: { on in Task { await appState.setTUN(on) } }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(appState.isBusy)
                            }

                            if appState.runtime.supportsSystemProxy {
                                HairlineDivider(inset: 56)
                                GroupedRow(
                                    title: "本地监听端口",
                                    subtitle: appState.status.running
                                        ? "内核运行中 · 停止内核后可修改本机监听端口"
                                        : "仅绑定 127.0.0.1 · 保存前自动校验端口冲突"
                                ) {
                                    settingsIcon("network", tint: .green)
                                } trailing: {
                                    HStack(spacing: 6) {
                                        portChip("MIX", text: $mixedPortText)
                                        portChip("HTTP", text: $httpPortText)
                                        portChip("SOCKS", text: $socksPortText)
                                        Button("保存") {
                                            savePorts()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(appState.status.running)
                                    }
                                }
                            }

                            HairlineDivider(inset: 56)
                            GroupedRow(
                                title: "代理故障时恢复直连",
                                subtitle: "节点连接失败时自动回退 DIRECT（显式 REJECT 规则始终阻断）。"
                            ) {
                                settingsIcon("arrow.uturn.right.circle.fill", tint: .orange)
                            } trailing: {
                                Toggle("", isOn: Binding(
                                    get: { appState.profile.fallbackToDirect },
                                    set: { on in
                                        Task {
                                            await appState.mutateProfile({
                                                try await appState.runtime.profileStore.setFallbackToDirect(on)
                                            })
                                        }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }
                        }
                    }
                }

                // Core & Probes
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeaderBar("内核与测速")
                    NativeCard(padding: 0) {
                        VStack(spacing: 0) {
                            GroupedRow(title: "IPv6 出站", subtitle: "允许内核使用 IPv6 地址建立出站连接。") {
                                Toggle("", isOn: coreSettingBinding(\.ipv6))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            HairlineDivider()
                            GroupedRow(title: "TCP 并发连接", subtitle: "域名解析出多个 IP 时同时建连并使用最快响应。") {
                                Toggle("", isOn: coreSettingBinding(\.tcpConcurrent))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            HairlineDivider()
                            GroupedRow(title: "统一延迟测试", subtitle: "复用已建立的连接测量延迟，减少握手误差。") {
                                Toggle("", isOn: coreSettingBinding(\.unifiedDelay))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            HairlineDivider()
                            GroupedRow(title: "内核日志级别", subtitle: "日常可选「信息」，排查连接问题可切换为「调试」。") {
                                HStack(spacing: 8) {
                                    Button("查看日志") {
                                        Task { coreLogSheetText = await appState.runtime.readCoreLogTail() }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Picker("日志级别", selection: coreSettingBinding(\.logLevel)) {
                                        Text("调试").tag("debug")
                                        Text("信息").tag("info")
                                        Text("警告").tag("warning")
                                        Text("错误").tag("error")
                                        Text("静默").tag("silent")
                                    }
                                    .labelsHidden()
                                    .frame(width: 96)
                                }
                            }
                            HairlineDivider()
                            GroupedRow(title: "延迟测试服务", subtitle: "用于手动测量节点延迟，批量测试支持自定义并发与超时。") {
                                HStack(spacing: 8) {
                                    Picker("服务", selection: $state.probeService) {
                                        ForEach(ProbeService.allCases) { svc in
                                            Text(svc.title).tag(svc)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 112)

                                    Picker("超时", selection: $state.probeTimeoutMs) {
                                        Text("2 秒").tag(2000)
                                        Text("5 秒").tag(5000)
                                        Text("7 秒").tag(7000)
                                    }
                                    .labelsHidden()
                                    .frame(width: 78)

                                    Picker("并发", selection: $state.probeConcurrency) {
                                        Text("2 并发").tag(2)
                                        Text("4 并发").tag(4)
                                        Text("8 并发").tag(8)
                                        Text("16 并发").tag(16)
                                    }
                                    .labelsHidden()
                                    .frame(width: 90)
                                }
                            }
                        }
                    }
                }

                // Network Details & Kernel Lifecycle
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeaderBar("网络详情与内核")
                    NativeCard(padding: 0) {
                        VStack(spacing: 0) {
                            let localText = appState.networkDetails.localAddresses.isEmpty
                                ? "本机地址读取中…"
                                : "本机 \(appState.networkDetails.localAddresses.prefix(3).joined(separator: "、"))"
                            let dnsText = appState.networkDetails.dnsServers.isEmpty
                                ? "DNS —"
                                : "DNS \(appState.networkDetails.dnsServers.prefix(3).joined(separator: "、"))"

                            GroupedRow(
                                title: "出口 IP 与终端代理变量",
                                subtitle: "出口 \(appState.networkDetails.exitIP ?? "未检测") · \(localText) · \(dnsText)"
                            ) {
                                settingsIcon("antenna.radiowaves.left.and.right", tint: .purple)
                            } trailing: {
                                HStack(spacing: 8) {
                                    if appState.runtime.supportsSystemProxy {
                                        Button("复制代理变量") {
                                            let port = appState.status.effectiveHTTPPort ?? appState.profile.mixedPort
                                            let cmd = "export http_proxy='http://127.0.0.1:\(port)' https_proxy='http://127.0.0.1:\(port)' all_proxy='http://127.0.0.1:\(port)'"
                                            ClipboardHelper.copy(cmd)
                                            appState.notify("已复制终端代理变量到剪贴板")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    Button("检测 IP") {
                                        Task { await appState.detectExitIP() }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }

                            HairlineDivider(inset: 56)

                            GroupedRow(
                                title: appState.status.running
                                    ? "\(appState.status.coreVersionLabel) 运行中"
                                    : "\(appState.status.coreVersionLabel) 已停止",
                                subtitle: "独立数据目录：\(appState.status.dataDirectory)"
                            ) {
                                settingsIcon("cpu", tint: .secondary)
                            } trailing: {
                                Button(appState.status.running ? "停止内核" : "启动内核") {
                                    Task { await appState.toggleLocalCore() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
            #else
            .frame(maxWidth: 860, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
        .navigationTitle("网络与设置")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("保存备份") {
                    Task {
                        do {
                            try await appState.runtime.profileStore.saveBackup()
                            appState.notify("已保存配置备份")
                        } catch {
                            appState.notify(error.localizedDescription, isError: true)
                        }
                    }
                }
                Button("恢复备份") {
                    Task {
                        await appState.mutateProfile({
                            try await appState.runtime.profileStore.restoreBackup()
                        }, successMessage: "已从备份恢复配置")
                    }
                }
            }
        }
        .onAppear {
            syncPortFields()
            Task { await appState.refreshNetworkDetails() }
        }
        .onChange(of: appState.profile.mixedPort) { _, _ in syncPortFields() }
        .sheet(item: Binding(
            get: { coreLogSheetText.map(LogTextBox.init) },
            set: { coreLogSheetText = $0?.text }
        )) { box in
            NavigationStack {
                ScrollView {
                    Text(box.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .navigationTitle("Mihomo 内核日志")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("复制") {
                            ClipboardHelper.copy(box.text)
                            appState.notify("已复制内核日志")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("关闭") { coreLogSheetText = nil }
                    }
                }
            }
            .frame(minWidth: 560, minHeight: 420)
        }
    }

    private func settingsIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func portChip(_ label: String, text: Binding<String>) -> some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 52)
                .disabled(appState.status.running)
        }
        #else
        let palette = XeylPalette(colorScheme)
        return HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("0", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .disabled(appState.status.running)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(palette.wellSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(palette.tileBorder, lineWidth: 0.75)
        )
        #endif
    }

    private func savePorts() {
        guard let m = UInt16(mixedPortText),
              let h = UInt16(httpPortText),
              let s = UInt16(socksPortText)
        else {
            appState.notify("端口须为 0–65535 的整数", isError: true)
            return
        }
        Task {
            await appState.mutateProfile({
                try await appState.runtime.profileStore.setPorts(mixed: m, http: h, socks: s)
            }, successMessage: "本地监听端口已保存")
        }
    }

    private func syncPortFields() {
        mixedPortText = "\(appState.profile.mixedPort)"
        httpPortText = "\(appState.profile.httpPort)"
        socksPortText = "\(appState.profile.socksPort)"
    }

    private func coreSettingBinding<T>(_ keyPath: WritableKeyPath<CoreSettings, T>) -> Binding<T> {
        Binding(
            get: { appState.profile.coreSettings[keyPath: keyPath] },
            set: { newValue in
                var updated = appState.profile.coreSettings
                updated[keyPath: keyPath] = newValue
                Task {
                    await appState.mutateProfile({
                        try await appState.runtime.profileStore.updateCoreSettings(updated)
                    })
                }
            }
        )
    }
}

private struct LogTextBox: Identifiable {
    let id = UUID()
    let text: String
}
