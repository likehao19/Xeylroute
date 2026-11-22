import SwiftUI
import XeylrouteCore

public struct LogsView: View {
    @Environment(AppState.self) private var appState

    enum LogsTab: String, CaseIterable, Identifiable {
        case history = "路由日志"
        case active = "活动连接"
        var id: String { rawValue }
    }

    @State private var selectedTab: LogsTab = .history
    @State private var filterText = ""
    @State private var probeHost = "github.com"
    @State private var probeSummary: String?
    @State private var prefillRule: RuleConditions?

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("视图", selection: $selectedTab) {
                    ForEach(LogsTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)

                Spacer()

                InlineSearchField(text: $filterText, placeholder: "搜索应用、目标或出口")
                    .frame(maxWidth: 220)

                HStack(spacing: 6) {
                    InlineSearchField(text: $probeHost, placeholder: "测试域名")
                        .frame(width: 160)
                        .onSubmit { runDomainProbe() }
                    Button("实测连通") { runDomainProbe() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if let probeSummary {
                NativeCard(padding: 10, radius: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
                        Text(probeSummary).font(.system(size: 12.5))
                        Spacer()
                        Button("关闭") { self.probeSummary = nil }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
            }

            ScrollView {
                VStack(spacing: 14) {
                    switch selectedTab {
                    case .history:
                        logsHistoryContent
                    case .active:
                        activeRoutesContent
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("连接记录")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if selectedTab == .active {
                    Button {
                        Task { await appState.refreshActiveRoutes() }
                    } label: {
                        Label("刷新连接", systemImage: "arrow.clockwise")
                    }
                } else {
                    Button("清空记录") {
                        appState.connectionLogs.removeAll()
                    }
                    .disabled(appState.connectionLogs.isEmpty)
                }
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .active {
                Task { await appState.refreshActiveRoutes() }
            }
        }
        .sheet(item: Binding(
            get: { prefillRule.map(PrefillWrapper.init) },
            set: { prefillRule = $0?.conditions }
        )) { wrapper in
            RuleEditorSheet(prefill: wrapper.conditions)
                .environment(appState)
        }
    }

    private var logsHistoryContent: some View {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = appState.connectionLogs.filter {
            query.isEmpty
                || $0.app.lowercased().contains(query)
                || $0.target.lowercased().contains(query)
                || $0.exit.lowercased().contains(query)
                || $0.decision.lowercased().contains(query)
        }

        return NativeCard(padding: 0) {
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("暂无连接记录")
                        .font(.headline)
                    Text("内核运行时会实时接收路由日志并保留最近 500 条事件。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(36)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                        GroupedRow(
                            title: row.target,
                            subtitle: "\(row.app.isEmpty ? "系统" : row.app) · \(row.decision)"
                        ) {
                            Text(row.time)
                                .font(.system(size: 11, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .leading)
                        } trailing: {
                            HStack(spacing: 6) {
                                StatusPill(text: row.protocolName, tint: .secondary)
                                StatusPill(
                                    text: row.exit,
                                    tint: row.failed ? .red : (row.exit == "DIRECT" ? .green : .blue)
                                )
                            }
                        }
                        if idx < rows.count - 1 {
                            HairlineDivider()
                        }
                    }
                }
            }
        }
    }

    private var activeRoutesContent: some View {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = appState.activeRoutes.filter {
            query.isEmpty
                || $0.displayApp.lowercased().contains(query)
                || $0.displayTarget.lowercased().contains(query)
                || $0.chains.joined(separator: " ").lowercased().contains(query)
        }

        return NativeCard(padding: 0) {
            if rows.isEmpty {
                Text("当前没有活动连接")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(36)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, route in
                        GroupedRow(
                            title: "\(route.displayApp) · \(route.displayTarget)",
                            subtitle: "\(route.rule)\(route.rulePayload.isEmpty ? "" : "(\(route.rulePayload))") → \(route.chains.reversed().joined(separator: " → "))"
                        ) {
                            Button("新建规则…") {
                                prefillRule = RuleConditions(
                                    program: route.programPath,
                                    target: route.host.isEmpty ? route.destinationIP : route.host,
                                    suffix: false,
                                    port: route.port
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        if idx < rows.count - 1 {
                            HairlineDivider()
                        }
                    }
                }
            }
        }
    }

    private func runDomainProbe() {
        let target = probeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        Task {
            do {
                if !appState.status.running {
                    _ = try await appState.runtime.startLocalCore()
                    await appState.refreshAll(fullSnapshot: true)
                }
                guard let client = await appState.runtime.activeClient() else {
                    probeSummary = "内核未运行，无法检测"
                    return
                }
                let result = try await client.probeWebsite(host: target, localProxyPort: appState.status.effectiveHTTPPort)
                probeSummary = "\(target)：HTTP \(result.status) · 响应 \(result.ms) ms"
            } catch {
                probeSummary = "\(target)：检测失败（\(error.localizedDescription)）"
            }
        }
    }
}

private struct PrefillWrapper: Identifiable {
    let id = UUID()
    let conditions: RuleConditions
}
