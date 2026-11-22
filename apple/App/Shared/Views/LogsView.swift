import SwiftUI
import XeylrouteCore

public struct LogsView: View {
    @Environment(AppState.self) private var appState

    enum LogsTab: String, CaseIterable, Identifiable {
        case history = "路由日志 (500)"
        case active = "活动连接"
        var id: String { rawValue }
    }

    @State private var selectedTab: LogsTab = .history
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
                .frame(maxWidth: 260)

                Spacer()

                HStack(spacing: 6) {
                    TextField("测试域名", text: $probeHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 190)
                        .onSubmit { runDomainProbe() }
                    Button("测试连通") { runDomainProbe() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if let probeSummary {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
                    Text(probeSummary).font(.caption)
                    Spacer()
                    Button("关闭") { self.probeSummary = nil }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
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
        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = appState.connectionLogs.filter {
            query.isEmpty
                || $0.app.lowercased().contains(query)
                || $0.target.lowercased().contains(query)
                || $0.exit.lowercased().contains(query)
                || $0.decision.lowercased().contains(query)
        }

        return NativeCard(padding: 0) {
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("暂无连接记录")
                        .font(.headline)
                    Text("内核运行时会实时接收路由日志并保留最近 500 条事件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                        HStack(spacing: 12) {
                            Text(row.time)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(row.target)
                                        .font(.subheadline.monospaced())
                                        .lineLimit(1)
                                    StatusPill(text: row.protocolName, tint: .secondary)
                                }
                                Text("\(row.app.isEmpty ? "系统" : row.app) · \(row.decision)")
                                    .font(.caption2)
                                    .foregroundStyle(row.failed ? .red : .secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            StatusPill(
                                text: row.exit,
                                tint: row.failed ? .red : (row.exit == "DIRECT" ? .green : .blue)
                            )
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        if idx < rows.count - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    private var activeRoutesContent: some View {
        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = appState.activeRoutes.filter {
            query.isEmpty
                || $0.displayApp.lowercased().contains(query)
                || $0.displayTarget.lowercased().contains(query)
                || $0.chains.joined(separator: " ").lowercased().contains(query)
        }

        return NativeCard(padding: 0) {
            if rows.isEmpty {
                Text("当前没有活动连接")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(32)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, route in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(route.displayApp)
                                        .font(.subheadline.weight(.semibold))
                                    Text(route.displayTarget)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text("\(route.rule)\(route.rulePayload.isEmpty ? "" : "(\(route.rulePayload))") → \(route.chains.reversed().joined(separator: " → "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
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
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        if idx < rows.count - 1 {
                            Divider().padding(.leading, 14)
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
