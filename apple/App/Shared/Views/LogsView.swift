import SwiftUI
import XeylrouteCore

public struct LogsView: View {
    @Environment(AppState.self) private var appState

    enum LogsTab: String, CaseIterable, Identifiable {
        case history = "路由日志"
        case active = "活动连接"
        var id: String { rawValue }
    }

    #if os(macOS)
    @State private var selectedLog: UUID?
    @State private var selectedRoute: String?
    #endif
    @State private var selectedTab: LogsTab = .history
    @State private var filterText = ""
    @State private var probeHost = "github.com"
    @State private var probeSummary: String?
    @State private var probing = false
    @State private var probeFailed = false
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

                #if os(iOS)
                InlineSearchField(text: $filterText, placeholder: "搜索应用、目标或出口")
                    .frame(maxWidth: 220)
                #endif

                HStack(spacing: 6) {
                    InlineSearchField(text: $probeHost, placeholder: "测试域名")
                        .frame(width: 160)
                        .onSubmit { runDomainProbe() }
                    Button(probing ? "检测中…" : "检测连接") { runDomainProbe() }
                        .disabled(probing || probeHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("通过本地代理检测网址，必要时启动监听")
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .workspaceControlBar()

            if let probeSummary {
                NativeCard(padding: 10, radius: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: probeFailed ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(probeFailed ? Color.orange : .green)
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

            #if os(macOS)
            switch selectedTab {
            case .history: logsHistoryContent
            case .active: activeRoutesContent
            }
            #else
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
            #endif
        }
        .navigationTitle("连接记录")
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .automatic) {
                WorkspaceSearch(query: $filterText, prompt: "搜索应用、目标或出口")
            }
            #endif
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

        #if os(macOS)
        return Table(rows, selection: $selectedLog) {
            TableColumn("时间", value: \.time).width(ideal: 78)
            TableColumn("应用") { Text($0.app.isEmpty ? "系统" : $0.app) }
            TableColumn("目标", value: \.target)
            TableColumn("协议", value: \.protocolName).width(ideal: 56)
            TableColumn("决策", value: \.decision)
            TableColumn("出口") { row in
                Text(row.exit).foregroundStyle(row.failed ? Color.red : .primary)
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if rows.isEmpty {
                CollectionEmptyState(title: "暂无连接记录", systemImage: "text.magnifyingglass",
                                     description: "启动内核后，这里显示最近的路由事件。", query: query)
            }
        }
        #else
        return NativeCard(padding: 0) {
            if rows.isEmpty {
                CollectionEmptyState(
                    title: "暂无连接记录",
                    systemImage: "text.magnifyingglass",
                    description: "内核运行时会实时接收路由日志并保留最近 500 条事件。",
                    query: query
                )
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
        #endif
    }

    private var activeRoutesContent: some View {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = appState.activeRoutes.filter {
            query.isEmpty
                || $0.displayApp.lowercased().contains(query)
                || $0.displayTarget.lowercased().contains(query)
                || $0.chains.joined(separator: " ").lowercased().contains(query)
        }

        #if os(macOS)
        return Table(rows, selection: $selectedRoute) {
            TableColumn("应用", value: \.displayApp)
            TableColumn("目标", value: \.displayTarget)
            TableColumn("规则") { Text($0.rulePayload.isEmpty ? $0.rule : "\($0.rule) · \($0.rulePayload)") }
            TableColumn("出口") { Text($0.chains.reversed().joined(separator: " → ")) }
            TableColumn("操作") { route in
                Button("新建规则…") { prepareRule(for: route) }
                    .buttonStyle(.borderless)
            }
            .width(74)
        }
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if rows.isEmpty {
                CollectionEmptyState(title: "当前没有活动连接", systemImage: "network",
                                     description: "通过代理建立的连接会出现在这里。", query: query)
            }
        }
        #else
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
                                prepareRule(for: route)
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
        #endif
    }

    private func prepareRule(for route: ActiveRoute) {
        prefillRule = RuleConditions(
            program: route.programPath,
            target: route.host.isEmpty ? route.destinationIP : route.host,
            suffix: false,
            port: route.port
        )
    }

    private func runDomainProbe() {
        let target = probeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !probing else { return }
        probing = true
        probeSummary = nil
        probeFailed = false
        Task {
            defer { probing = false }
            do {
                if !appState.status.running {
                    _ = try await appState.runtime.startLocalCore()
                    await appState.refreshAll(fullSnapshot: true)
                }
                guard let client = await appState.runtime.activeClient() else {
                    probeFailed = true
                    probeSummary = "本地监听尚未就绪，请稍后重试。"
                    return
                }
                let result = try await client.probeWebsite(host: target, localProxyPort: appState.status.effectiveHTTPPort)
                probeFailed = !(200..<400).contains(result.status)
                probeSummary = "\(target)：HTTP \(result.status) · 响应 \(result.ms) ms"
            } catch {
                probeFailed = true
                probeSummary = "\(target)：检测失败（\(error.localizedDescription)）"
            }
        }
    }
}

private struct PrefillWrapper: Identifiable {
    let id = UUID()
    let conditions: RuleConditions
}
