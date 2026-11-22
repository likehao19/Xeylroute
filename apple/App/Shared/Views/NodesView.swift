import SwiftUI
import XeylrouteCore

public struct NodesView: View {
    @Environment(AppState.self) private var appState

    enum NodesTab: String, CaseIterable, Identifiable {
        case groups = "节点列表"
        case sites = "常用网站测速"
        case socks = "固定 SOCKS5 入口"
        var id: String { rawValue }
    }

    @State private var selectedTab: NodesTab = .groups
    @State private var expandedGroups: Set<String> = ["GLOBAL"]
    @State private var showAddSocksSheet = false
    @State private var clashSnippetBinding: FixedSocksBinding?

    private var availableTabs: [NodesTab] {
        appState.runtime.supportsFixedSocks ? NodesTab.allCases : [.groups, .sites]
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("视图", selection: $selectedTab) {
                    ForEach(availableTabs) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)

                Spacer()

                if let scope = appState.profile.subscriptionScope {
                    StatusPill(text: "当前订阅：\(scope)", tint: .blue)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 14) {
                    switch selectedTab {
                    case .groups:
                        nodesGroupsContent
                    case .sites:
                        websiteProbeContent
                    case .socks:
                        fixedSocksContent
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("代理组与节点")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                switch selectedTab {
                case .groups:
                    Button("测全部带宽") {
                        Task { await appState.measureAllBandwidth() }
                    }
                    .disabled(appState.isBatchProbing || !appState.status.configured)

                    Button(appState.isBatchProbing ? "测速中…" : "全部测延迟") {
                        Task { await appState.measureAllDelays() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.isBatchProbing || !appState.status.configured)

                case .sites:
                    Button("全部站点测速") {
                        Task { await appState.probeAllWebsites() }
                    }
                    .buttonStyle(.borderedProminent)

                case .socks:
                    Button {
                        showAddSocksSheet = true
                    } label: {
                        Label("添加固定入口", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showAddSocksSheet) {
            AddFixedSocksSheet()
                .environment(appState)
        }
        .sheet(item: $clashSnippetBinding) { binding in
            ClashSnippetSheet(binding: binding)
        }
    }

    // MARK: - Nodes & Policy Groups

    private var nodesGroupsContent: some View {
        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredNodes = appState.selectableNodes.filter { node in
            query.isEmpty || node.name.lowercased().contains(query) || node.type.lowercased().contains(query)
        }

        return VStack(spacing: 14) {
            if !appState.status.configured {
                NativeCard(padding: 28) {
                    VStack(spacing: 10) {
                        Image(systemName: "network.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("还没有代理节点")
                            .font(.headline)
                        Text("前往「订阅管理」导入订阅链接、节点分享链接或 YAML 配置文件。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("前往导入") {
                            appState.selectedDestination = .subscriptions
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                groupDrawer(
                    id: "GLOBAL",
                    title: "全局默认出口",
                    subtitle: "当前使用 \(appState.currentGlobalExit)",
                    nodes: filteredNodes,
                    selectedName: appState.currentGlobalExit
                )

                ForEach(appState.profile.groups) { group in
                    let live = appState.snapshot?.proxies[group.name]
                    let memberNames = live?.all ?? group.proxies
                    let memberNodes = memberNames.map { name in
                        appState.selectableNodes.first(where: { $0.name == name })
                            ?? ProxyNode(name: name, type: "策略成员", isPolicy: ["AUTO", "DIRECT", "REJECT"].contains(name))
                    }
                    groupDrawer(
                        id: group.name,
                        title: group.name,
                        subtitle: "\(group.type) · 当前 \(live?.now ?? "未启动")",
                        nodes: memberNodes,
                        selectedName: live?.now ?? ""
                    )
                }
            }
        }
    }

    private func groupDrawer(
        id: String,
        title: String,
        subtitle: String,
        nodes: [ProxyNode],
        selectedName: String
    ) -> some View {
        let isExpanded = expandedGroups.contains(id)
        return NativeCard(padding: 0) {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isExpanded { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.headline)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                        ForEach(nodes) { node in
                            let selected = node.name == selectedName
                            HStack(spacing: 8) {
                                Button {
                                    Task { await appState.selectNode(node.name, inGroup: id) }
                                } label: {
                                    HStack(spacing: 8) {
                                        CountryBadge(nodeName: node.name, isPolicy: node.isPolicy)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(node.name)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                            Text(node.currentSelection ?? node.type)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 4)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                LatencyBadge(
                                    measurement: appState.nodeDelays[node.id],
                                    isTesting: appState.testingNodes.contains(node.id)
                                )

                                if !node.isPolicy || node.name == "AUTO" {
                                    Button {
                                        Task { await appState.measureDelay(for: node) }
                                    } label: {
                                        Image(systemName: "gauge.with.dots.needle.33percent")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("测试延迟")
                                }
                            }
                            .padding(10)
                            .background(
                                selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: 1)
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    // MARK: - Website Probes

    private var websiteProbeContent: some View {
        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = appState.websites.filter {
            query.isEmpty || $0.name.lowercased().contains(query) || $0.host.lowercased().contains(query)
        }
        return NativeCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, site in
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(site.name).font(.subheadline.weight(.medium))
                                StatusPill(text: site.category, tint: .secondary)
                            }
                            Text(site.host)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if site.isTesting {
                            ProgressView().controlSize(.small)
                        } else if let err = site.error {
                            Text(err).font(.caption).foregroundStyle(.red)
                        } else if let ms = site.latencyMs {
                            Text("\(ms) ms · HTTP \(site.httpStatus ?? 200)")
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(ms < 300 ? .green : .orange)
                        } else {
                            Text("未测").font(.caption).foregroundStyle(.tertiary)
                        }
                        Button("测试") {
                            Task { await appState.probeWebsite(site.host) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if idx < items.count - 1 {
                        Divider().padding(.leading, 48)
                    }
                }
            }
        }
    }

    // MARK: - Fixed Loopback SOCKS5 Listeners

    private var fixedSocksContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeCard {
                HStack(spacing: 12) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("单节点固定本机 SOCKS5 入口")
                            .font(.subheadline.weight(.semibold))
                        Text("仅监听 127.0.0.1，支持 TCP 与 UDP；切换首页默认节点不影响已绑定的固定出口，适合提供给其他客户端或 Clash 规则使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            NativeCard(padding: 0) {
                if appState.profile.fixedSocks.isEmpty {
                    Text("尚未创建固定 SOCKS5 入口，点击右上角「添加固定入口」创建。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(28)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(appState.profile.fixedSocks.enumerated()), id: \.element.id) { idx, binding in
                            HStack(spacing: 12) {
                                Text("127.0.0.1:\(binding.port)")
                                    .font(.subheadline.monospaced().weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(binding.node)
                                        .font(.subheadline.weight(.medium))
                                    Text(binding.provider.map { "订阅：\($0)" } ?? "独立节点")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Clash 配置…") {
                                    clashSnippetBinding = binding
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button(role: .destructive) {
                                    Task {
                                        await appState.mutateProfile({
                                            try await appState.runtime.profileStore.removeFixedSocks(binding)
                                        }, successMessage: "已移除端口 \(binding.port) 入口")
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            if idx < appState.profile.fixedSocks.count - 1 {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AddFixedSocksSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var portText = "19081"
    @State private var selectedNodeID = ""

    private var candidates: [ProxyNode] {
        appState.selectableNodes.filter { !$0.isPolicy }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("本机 SOCKS5 端口 (127.0.0.1)", text: $portText)
                Picker("绑定节点", selection: $selectedNodeID) {
                    ForEach(candidates) { node in
                        Text("\(node.name)\(node.provider.map { " · \($0)" } ?? "")").tag(node.id)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("添加固定 SOCKS5 入口")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)),
                              let node = candidates.first(where: { $0.id == selectedNodeID }) ?? candidates.first
                        else { return }
                        Task {
                            await appState.mutateProfile({
                                try await appState.runtime.profileStore.addFixedSocks(
                                    FixedSocksBinding(port: port, node: node.name, provider: node.provider)
                                )
                            }, successMessage: "已绑定 127.0.0.1:\(port) → \(node.name)")
                            dismiss()
                        }
                    }
                    .disabled(UInt16(portText.trimmingCharacters(in: .whitespaces)) == nil || candidates.isEmpty)
                }
            }
            .onAppear {
                if selectedNodeID.isEmpty, let first = candidates.first {
                    selectedNodeID = first.id
                }
            }
        }
        .frame(minWidth: 400, minHeight: 220)
    }
}

private struct ClashSnippetSheet: View {
    let binding: FixedSocksBinding
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        let snippet = ProfileStore.clashSnippet(for: binding)
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("将以下片段并入 Clash 的现有配置（需在规则模式下使用），Xeylroute 保持本地监听即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(snippet)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
            .navigationTitle("Clash 配置片段 · :\(binding.port)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? "已复制" : "复制片段") {
                        ClipboardHelper.copy(snippet)
                        copied = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 300)
    }
}
