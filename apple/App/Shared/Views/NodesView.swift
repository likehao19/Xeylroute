import SwiftUI
import XeylrouteCore

public struct NodesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    enum NodesTab: String, CaseIterable, Identifiable {
        case groups = "节点列表"
        case sites = "常用网站测速"
        case socks = "固定 SOCKS5 入口"
        var id: String { rawValue }
    }

    #if os(macOS)
    @State private var selectedGroup = "GLOBAL"
    @State private var showImport = false
    #endif
    @State private var selectedTab: NodesTab = .groups
    @State private var expandedGroups: Set<String> = ["GLOBAL"]
    @State private var filterText = ""
    @State private var showAddSocksSheet = false
    @State private var clashSnippetBinding: FixedSocksBinding?

    private var hasBindableNodes: Bool { appState.selectableNodes.contains { !$0.isPolicy } }

    private var availableTabs: [NodesTab] {
        appState.runtime.supportsFixedSocks ? NodesTab.allCases : [.groups, .sites]
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("视图", selection: $selectedTab) {
                    ForEach(availableTabs) { tab in
                        #if os(macOS)
                        Text(tab == .socks ? "固定入口" : (tab == .sites ? "网站测速" : tab.rawValue)).tag(tab)
                        #else
                        Text(tab.rawValue).tag(tab)
                        #endif
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                #if os(macOS)
                .fixedSize()
                #else
                .frame(maxWidth: 340)
                #endif

                Spacer()

                #if os(iOS)
                InlineSearchField(text: $filterText, placeholder: selectedTab == .sites ? "搜索网站" : "搜索节点或协议")
                    .frame(maxWidth: 220)
                #endif

                #if os(macOS)
                if selectedTab == .groups && appState.profile.groups.contains(where: { $0.enabled && $0.name != "GLOBAL" }) {
                    Picker("策略组", selection: Binding(
                        get: { appState.profile.groups.contains { $0.name == selectedGroup && $0.enabled } ? selectedGroup : "GLOBAL" },
                        set: { selectedGroup = $0 }
                    )) {
                        Text("默认出口").tag("GLOBAL")
                        ForEach(appState.profile.groups.filter { $0.enabled && $0.name != "GLOBAL" }) { Text($0.name).tag($0.name) }
                    }
                    .frame(maxWidth: 210)
                }
                #else
                if let scope = appState.profile.subscriptionScope {
                    StatusPill(text: scope, tint: .blue)
                }
                #endif
            }
            .workspaceControlBar()

            #if os(macOS)
            if selectedTab == .socks && appState.profile.fixedSocks.isEmpty && filterText.isEmpty {
                WorkspacePlaceholder(symbol: "point.topleft.down.to.point.bottomright.curvepath",
                                     title: "还没有固定入口",
                                     detail: "将本机 SOCKS5 端口绑定到一个节点，应用就能始终使用这个出口。",
                                     actionTitle: hasBindableNodes ? "创建 SOCKS5 入口…" : "先导入节点…") {
                    if hasBindableNodes { showAddSocksSheet = true } else { showImport = true }
                }
            } else if selectedTab == .groups && (hasBindableNodes || !appState.profile.groups.isEmpty) {
                macNodeCatalog
            } else {
                tabContent
            }
            #else
            tabContent
            #endif
        }
        .workspaceTitle(.nodes)
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .automatic) {
                WorkspaceSearch(query: $filterText, prompt: selectedTab == .sites ? "搜索网站" : (selectedTab == .socks ? "搜索节点、端口或订阅" : "搜索节点或协议"))
            }
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                switch selectedTab {
                case .groups:
                    #if os(macOS)
                    Menu {
                        Button("全部测延迟") { Task { await appState.measureAllDelays() } }
                        Button("测全部带宽") { Task { await appState.measureAllBandwidth() } }
                    } label: {
                        Label(appState.isBatchProbing ? "测速中…" : "批量测速", systemImage: "speedometer")
                    }
                    .disabled(appState.isBatchProbing || appState.proxyServers.isEmpty)
                    #else
                    Button("测全部带宽") {
                        Task { await appState.measureAllBandwidth() }
                    }
                    .disabled(appState.isBatchProbing || !hasBindableNodes)

                    Button(appState.isBatchProbing ? "测速中…" : "全部测延迟") {
                        Task { await appState.measureAllDelays() }
                    }
                    .workspaceToolbarPrimary()
                    .disabled(appState.isBatchProbing || !hasBindableNodes)

                    #endif
                case .sites:
                    Button("全部站点测速") {
                        Task { await appState.probeAllWebsites() }
                    }
                    .workspaceToolbarPrimary()

                case .socks:
                    Button {
                        showAddSocksSheet = true
                    } label: {
                        Label("添加固定入口", systemImage: "plus")
                    }
                    .disabled(!hasBindableNodes)
                    .workspaceToolbarPrimary()
                }
            }
        }
        #if os(macOS)
        .onAppear {
            if appState.openFixedListeners {
                selectedTab = .socks
                appState.openFixedListeners = false
            }
        }
        .sheet(isPresented: $showImport) { ImportSubscriptionSheet() }
        #endif
        .sheet(isPresented: $showAddSocksSheet) {
            AddFixedSocksSheet()
                .environment(appState)
        }
        .sheet(item: $clashSnippetBinding) { binding in
            ClashSnippetSheet(binding: binding)
        }
    }

    private var tabContent: some View {
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

    #if os(macOS)
    private var macNodeCatalog: some View {
        let group = appState.profile.groups.first { $0.name == selectedGroup && $0.enabled }
        let groupName = group?.name ?? "GLOBAL"
        let nodes = group.map(groupMembers) ?? appState.selectableNodes
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = nodes.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.type.localizedCaseInsensitiveContains(query) }
        let active = appState.snapshot?.proxies[groupName]?.now
        let policies = rows.filter(\.isPolicy)
        let servers = rows.filter { !$0.isPolicy }

        let notices = servers.filter(\.isSubscriptionNote)
        let endpoints = servers.filter { !$0.isSubscriptionNote }
        return ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                if !policies.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("出口策略").font(.headline)
                            Spacer()
                            if let active { Text("当前 · " + active).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(policies) { node in
                                    let title = ["AUTO": "自动优选", "DIRECT": "直连", "REJECT": "阻断"][node.name] ?? node.name
                                    Button {
                                        Task { await appState.selectNode(node.name, inGroup: groupName) }
                                    } label: {
                                        HStack(spacing: 5) {
                                            CountryBadge(nodeName: node.name, isPolicy: true)
                                            Text(title)
                                            if active == node.name { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                        }
                                    }.controlSize(.small).help(node.name)
                                }
                            }
                        }.scrollIndicators(.automatic)
                    }
                }
                if !endpoints.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("可用节点").font(.headline)
                            Spacer()
                            Text("\(endpoints.count) 个节点").font(.caption).foregroundStyle(.secondary)
                        }
                        WorkspaceNodeList(nodes: endpoints, selectedName: active) { node in
                            Task { await appState.selectNode(node.name, inGroup: groupName) }
                        }
                    }
                } else if rows.isEmpty {
                    CollectionEmptyState(title: "分组中还没有节点", systemImage: "network",
                                         description: "编辑策略组或切换到默认出口。", query: query)
                }
                SubscriptionNotes(notes: notices, searching: !query.isEmpty)
            }.padding(20)
        }
    }
    #endif

    private func groupMembers(_ group: PolicyGroup) -> [ProxyNode] {
        let sourceNodes = appState.profile.providers.filter { group.use.contains($0.name) }.flatMap { $0.nodes.map(\.name) }
        let names = appState.snapshot?.proxies[group.name]?.all ?? (group.proxies + sourceNodes.filter { !group.proxies.contains($0) })
        let available = appState.selectableNodes
        return names.map { name in
            available.first { $0.name == name }
                ?? ProxyNode(name: name, type: "策略成员", isPolicy: ["AUTO", "DIRECT", "REJECT"].contains(name))
        }
    }

    // MARK: - Nodes & Policy Groups

    private var nodesGroupsContent: some View {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredNodes = appState.selectableNodes.filter { node in
            query.isEmpty || node.name.lowercased().contains(query) || node.type.lowercased().contains(query)
        }

        return VStack(spacing: 14) {
            if !hasBindableNodes && appState.profile.groups.isEmpty {
                NativeCard(padding: 36) {
                    VStack(spacing: 10) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("还没有代理节点")
                            .font(.headline)
                        Text("导入订阅或节点后，可以在这里切换出口、测试延迟。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Button("导入订阅或节点…") {
                            #if os(macOS)
                            showImport = true
                            #else
                            appState.selectedDestination = .subscriptions
                            #endif
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
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
                    groupDrawer(
                        id: group.name,
                        title: group.name,
                        subtitle: "\(group.type) · 当前 \(live?.now ?? "未启动")",
                        nodes: groupMembers(group),
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
        func nodeRow(_ node: ProxyNode) -> some View {
            NodeDrawerTile(
                node: node,
                isSelected: node.name == selectedName,
                measurement: appState.nodeDelays[node.id],
                isTesting: appState.testingNodes.contains(node.id),
                onSelect: { Task { await appState.selectNode(node.name, inGroup: id) } },
                onProbe: { Task { await appState.measureDelay(for: node) } }
            )
        }

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
                                .font(.system(size: 14, weight: .semibold))
                            Text(subtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    HairlineDivider(inset: 0)
                    #if os(macOS)
                    LazyVStack(spacing: 0) {
                        ForEach(nodes) { node in
                            nodeRow(node)
                            if node.id != nodes.last?.id { HairlineDivider(inset: 52) }
                        }
                    }
                    #else
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                        ForEach(nodes) { node in nodeRow(node) }
                    }
                    .padding(14)
                    #endif
                }
            }
        }
    }

    // MARK: - Website Probes

    private var websiteProbeContent: some View {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = appState.websites.filter {
            query.isEmpty || $0.name.lowercased().contains(query) || $0.host.lowercased().contains(query)
        }
        return NativeCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, site in
                    GroupedRow(title: site.name, subtitle: site.host) {
                        Image(systemName: "globe")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.blue)
                            .frame(width: 28, height: 28)
                            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } trailing: {
                        HStack(spacing: 10) {
                            StatusPill(text: site.category, tint: .secondary)
                            if site.isTesting {
                                ProgressView().controlSize(.mini)
                            } else if let err = site.error {
                                Text(err)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.red)
                            } else if let ms = site.latencyMs {
                                Text("\(ms) ms · HTTP \(site.httpStatus ?? 200)")
                                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(ms < 300 ? .green : .orange)
                            } else {
                                Text("未测")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.tertiary)
                            }
                            Button("测试") {
                                Task { await appState.probeWebsite(site.host) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    if idx < items.count - 1 {
                        HairlineDivider(inset: 56)
                    }
                }
            }
        }
    }

    // MARK: - Fixed Loopback SOCKS5 Listeners

    private var fixedSocksContent: some View {
        let palette = XeylPalette(colorScheme)
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bindings = appState.profile.fixedSocks.filter {
            query.isEmpty || $0.node.localizedCaseInsensitiveContains(query)
                || String($0.port).contains(query) || ($0.provider?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return VStack(alignment: .leading, spacing: 14) {
            NativeCard(padding: 15) {
                HStack(spacing: 12) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 32, height: 32)
                        .background(Color.blue.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("单节点固定本机 SOCKS5 入口")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("仅监听 127.0.0.1，支持 TCP 与 UDP；切换首页默认节点不影响已绑定的固定出口，适合提供给其他客户端或 Clash 规则使用。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            NativeCard(padding: 0) {
                if bindings.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if bindings.isEmpty {
                    Text("尚未创建固定 SOCKS5 入口，点击右上角「添加固定入口」创建。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(32)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(bindings.enumerated()), id: \.element.id) { idx, binding in
                            GroupedRow(
                                title: binding.node,
                                subtitle: binding.provider.map { "订阅：\($0)" } ?? "独立节点"
                            ) {
                                Text("127.0.0.1:\(String(binding.port))")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(palette.wellSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            } trailing: {
                                HStack(spacing: 8) {
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
                            }
                            if idx < bindings.count - 1 {
                                HairlineDivider()
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct NodeDrawerTile: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    let node: ProxyNode
    let isSelected: Bool
    let measurement: DelayMeasurement?
    let isTesting: Bool
    let onSelect: () -> Void
    let onProbe: () -> Void

    var body: some View {
        let palette = XeylPalette(colorScheme)
        #if os(iOS)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        #endif

        HStack(spacing: 9) {
            Button(action: onSelect) {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            #if os(macOS)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(.tint)
                    .accessibilityLabel("当前节点")
            }
            #endif
            LatencyBadge(measurement: measurement, isTesting: isTesting)

            if !node.isPolicy || node.name == "AUTO" {
                Button(action: onProbe) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("测试延迟")
            }
        }
        #if os(macOS)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isSelected ? palette.selectedFill : (isHovering ? palette.rowHover : .clear))
        #else
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
        #endif
        .onHover { isHovering = $0 }
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
                    .buttonStyle(.borderedProminent)
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
