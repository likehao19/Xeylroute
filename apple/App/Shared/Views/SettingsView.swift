import SwiftUI
import XeylrouteCore

public struct SettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var mixedPortText = "7890"
    @State private var httpPortText = "0"
    @State private var socksPortText = "0"
    @State private var coreLogSheetText: String?

    public var body: some View {
        @Bindable var state = appState

        return Form {
            Section("外观") {
                Picker("外观模式", selection: $state.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("网络接管") {
                if appState.runtime.supportsSystemProxy {
                    Toggle("macOS 系统代理", isOn: Binding(
                        get: { appState.status.systemProxyEnabled },
                        set: { on in Task { await appState.setSystemProxy(on) } }
                    ))
                    .disabled(appState.isBusy)
                }

                Toggle(appState.runtime.supportsSystemProxy ? "虚拟网卡 (TUN)" : "iOS VPN 隧道", isOn: Binding(
                    get: { appState.status.tunEnabled },
                    set: { on in Task { await appState.setTUN(on) } }
                ))
                .disabled(appState.isBusy)

                LabeledContent("TUN 接管范围") {
                    Text(appState.profile.tunScope.title)
                        .foregroundStyle(.secondary)
                }

                Toggle("代理故障时恢复直连", isOn: Binding(
                    get: { appState.profile.fallbackToDirect },
                    set: { on in
                        Task {
                            await appState.mutateProfile({
                                try await appState.runtime.profileStore.setFallbackToDirect(on)
                            })
                        }
                    }
                ))
            }

            if appState.runtime.supportsSystemProxy {
                Section("本地监听端口（仅绑定 127.0.0.1）") {
                    HStack(spacing: 12) {
                        portField("MIX", text: $mixedPortText)
                        portField("HTTP", text: $httpPortText)
                        portField("SOCKS", text: $socksPortText)
                        Button("保存") {
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
                        .disabled(appState.status.running)
                    }
                    if appState.status.running {
                        Text("修改监听端口前请先停止代理内核。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("内核设置") {
                Toggle("IPv6 出站", isOn: coreSettingBinding(\.ipv6))
                Toggle("TCP 并发连接", isOn: coreSettingBinding(\.tcpConcurrent))
                Toggle("统一延迟测试", isOn: coreSettingBinding(\.unifiedDelay))

                Picker("内核日志级别", selection: coreSettingBinding(\.logLevel)) {
                    Text("调试 (debug)").tag("debug")
                    Text("信息 (info)").tag("info")
                    Text("警告 (warning)").tag("warning")
                    Text("错误 (error)").tag("error")
                    Text("静默 (silent)").tag("silent")
                }

                Button("查看内核运行日志…") {
                    Task {
                        coreLogSheetText = await appState.runtime.readCoreLogTail()
                    }
                }
            }

            Section("手动测速") {
                Picker("延迟测试服务", selection: $state.probeService) {
                    ForEach(ProbeService.allCases) { svc in
                        Text(svc.title).tag(svc)
                    }
                }
                Picker("延迟超时", selection: $state.probeTimeoutMs) {
                    Text("2 秒").tag(2000)
                    Text("5 秒").tag(5000)
                    Text("7 秒").tag(7000)
                }
                Picker("批量测速并发数", selection: $state.probeConcurrency) {
                    Text("2 个").tag(2)
                    Text("4 个").tag(4)
                    Text("8 个").tag(8)
                    Text("16 个").tag(16)
                }
            }

            Section("网络详情与诊断") {
                LabeledContent("出口 IP") {
                    HStack(spacing: 8) {
                        Text(appState.networkDetails.exitIP ?? "未检测")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                        Button("检测 IP") {
                            Task { await appState.detectExitIP() }
                        }
                        .controlSize(.small)
                    }
                }

                if appState.runtime.supportsSystemProxy {
                    LabeledContent("本机地址") {
                        Text(appState.networkDetails.localAddresses.isEmpty
                             ? "—"
                             : appState.networkDetails.localAddresses.joined(separator: "、"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("系统 DNS") {
                        Text(appState.networkDetails.dnsServers.isEmpty
                             ? "—"
                             : appState.networkDetails.dnsServers.joined(separator: "、"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Button("复制终端代理环境变量") {
                        let port = appState.status.effectiveHTTPPort ?? appState.profile.mixedPort
                        let cmd = "export http_proxy='http://127.0.0.1:\(port)' https_proxy='http://127.0.0.1:\(port)' all_proxy='http://127.0.0.1:\(port)'"
                        ClipboardHelper.copy(cmd)
                        appState.notify("已复制终端代理变量到剪贴板")
                    }
                }

                LabeledContent("数据目录") {
                    Text(appState.status.dataDirectory)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }

                LabeledContent("内核状态") {
                    HStack(spacing: 8) {
                        Text(appState.status.running ? "运行中 (\(appState.status.coreVersionLabel))" : "已停止")
                            .foregroundStyle(.secondary)
                        Button(appState.status.running ? "停止内核" : "启动内核") {
                            Task { await appState.toggleLocalCore() }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("配置备份") {
                HStack {
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
                    Spacer()
                    Button("恢复备份") {
                        Task {
                            await appState.mutateProfile({
                                try await appState.runtime.profileStore.restoreBackup()
                            }, successMessage: "已从备份恢复配置")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("网络与设置")
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

    private func syncPortFields() {
        mixedPortText = "\(appState.profile.mixedPort)"
        httpPortText = "\(appState.profile.httpPort)"
        socksPortText = "\(appState.profile.socksPort)"
    }

    private func portField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("0", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 68)
                .disabled(appState.status.running)
        }
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
