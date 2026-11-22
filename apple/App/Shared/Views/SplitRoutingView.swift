import SwiftUI
import XeylrouteCore
#if os(macOS)
import AppKit
#endif

public struct SplitRoutingView: View {
    @Environment(AppState.self) private var appState

    enum SplitTab: String, CaseIterable, Identifiable {
        case rules = "分流规则"
        case groups = "策略分组"
        case apps = "运行中的应用"
        var id: String { rawValue }
    }

    #if os(macOS)
    @State private var selectedRule: String?
    #endif
    @State private var selectedTab: SplitTab = .rules
    @State private var filterText = ""
    @State private var scanByProcess = false
    @State private var editingRule: ProfileRule?
    @State private var showAddRule = false
    @State private var showAddGroup = false
    @State private var editingGroup: PolicyGroup?
    @State private var showEffectiveOrder = false

    private var availableTabs: [SplitTab] {
        appState.runtime.supportsProcessRouting ? SplitTab.allCases : [.rules, .groups]
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("分页", selection: $selectedTab) {
                    ForEach(availableTabs) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                #if os(macOS)
                .fixedSize()
                #else
                .frame(maxWidth: 320)
                #endif

                Spacer()

                #if os(iOS)
                InlineSearchField(text: $filterText, placeholder: selectedTab == .apps ? "搜索应用或路径" : "搜索规则或分组")
                    .frame(maxWidth: 220)
                #endif

                if selectedTab == .rules {
                    HStack(spacing: 6) {
                        Text("未命中规则时")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        let defaultExit = appState.profile.rules.last(where: \.isDefaultMatch)?.exit ?? "AUTO"
                        Menu {
                            ForEach(appState.profile.exits, id: \.self) { exit in
                                Button(exit) {
                                    Task {
                                        await appState.mutateProfile({
                                            try await appState.runtime.profileStore.setDefaultExit(exit)
                                        }, successMessage: "默认出口已设为 \(exit)")
                                    }
                                }
                            }
                        } label: {
                            StatusPill(text: defaultExit, tint: .blue)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                } else if selectedTab == .apps {
                    Picker("视角", selection: $scanByProcess) {
                        Text("按应用").tag(false)
                        Text("按进程").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
            .workspaceControlBar()

            #if os(macOS)
            if selectedTab == .rules {
                rulesListContent
            } else if selectedTab == .apps {
                processDirectory.macTableSurface().task { await appState.refreshProcesses() }
            } else {
                tabContent
            }
            #else
            tabContent
            #endif
        }
        .workspaceTitle(.split)
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .automatic) {
                WorkspaceSearch(query: $filterText, prompt: selectedTab == .apps ? "搜索应用或路径" : "搜索规则或分组")
            }
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                if selectedTab == .rules {
                    Button("生效顺序") {
                        showEffectiveOrder = true
                    }
                    Button {
                        editingRule = nil
                        showAddRule = true
                    } label: {
                        Label("添加规则", systemImage: "plus")
                    }
                    .workspaceToolbarPrimary()
                } else if selectedTab == .groups {
                    Button {
                        editingGroup = nil
                        showAddGroup = true
                    } label: {
                        Label("新建分组", systemImage: "plus")
                    }
                    .workspaceToolbarPrimary()
                } else {
                    Button {
                        Task { await appState.refreshProcesses() }
                    } label: {
                        Label("刷新程序", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddRule) {
            RuleEditorSheet(existing: editingRule)
                .environment(appState)
        }
        .sheet(isPresented: $showAddGroup) {
            GroupEditorSheet(existing: editingGroup)
                .environment(appState)
        }
        .sheet(isPresented: $showEffectiveOrder) {
            EffectiveOrderSheet()
                .environment(appState)
        }
    }

    private var tabContent: some View {
        ScrollView {
            VStack(spacing: 14) {
                switch selectedTab {
                case .rules:
                    rulesListContent
                case .groups:
                    groupsListContent
                case .apps:
                    #if os(iOS)
                    runningAppsContent
                    #else
                    EmptyView()
                    #endif
                }
            }
            .padding(20)
        }
    }

    // MARK: - Rules

    @ViewBuilder
    private var rulesListContent: some View {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = appState.profile.rules.filter { rule in
            !rule.isDefaultMatch && (query.isEmpty || rule.rawLine.lowercased().contains(query))
        }

        #if os(macOS)
        if items.isEmpty {
            if query.isEmpty {
                WorkspacePlaceholder(symbol: "arrow.triangle.branch", title: "还没有分流规则",
                                     detail: "可以让指定网站走代理，或让某个应用始终直连。规则按列表顺序匹配。",
                                     actionTitle: "创建分流规则…") {
                    editingRule = nil
                    showAddRule = true
                }
            } else {
                ContentUnavailableView.search(text: filterText)
            }
        } else {
            GeometryReader { area in
                Table(items, selection: $selectedRule) {
                    TableColumn("匹配条件") { rule in
                        Label(rule.payload.isEmpty ? rule.kind : rule.payload, systemImage: iconForRule(rule))
                    }
                    TableColumn("类型") { rule in
                        Text(rule.kind).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.width(ideal: 105)
                    TableColumn("出口") { rule in
                        StatusPill(text: rule.exit, tint: rule.exit == "DIRECT" ? .teal : (rule.exit == "REJECT" ? .red : .blue))
                    }.width(ideal: 82)
                    TableColumn("操作") { rule in
                        HStack(spacing: 10) { ruleControls(rule) }
                    }
                    .width(106)
                }
                .alternatingRowBackgrounds(.disabled)
                .environment(\.defaultMinListRowHeight, 35)
                .frame(height: min(max(0, area.size.height - 18), 35 * CGFloat(items.count) + 36))
                .macTableSurface()
            }
        }
        #else
        NativeCard(padding: 0) {
            if items.isEmpty {
                CollectionEmptyState(
                    title: "暂无分流规则",
                    systemImage: "arrow.triangle.branch",
                    description: "支持按程序路径、域名/后缀、IP/CIDR 网段和目标端口进行组合分流。",
                    query: query
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, rule in
                        GroupedRow(title: rule.payload.isEmpty ? rule.kind : rule.payload, subtitle: rule.kind) {
                            Image(systemName: iconForRule(rule))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(colorForRule(rule))
                                .frame(width: 28, height: 28)
                                .background(colorForRule(rule).opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        } trailing: {
                            HStack(spacing: 10) {
                                StatusPill(
                                    text: rule.exit,
                                    tint: rule.exit == "DIRECT" ? .green : (rule.exit == "REJECT" ? .red : .blue)
                                )
                                ruleControls(rule)
                            }
                        }
                        if idx < items.count - 1 {
                            HairlineDivider(inset: 56)
                        }
                    }
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func ruleControls(_ rule: ProfileRule) -> some View {
        Toggle("", isOn: Binding(
            get: { rule.enabled },
            set: { enabled in
                Task {
                    await appState.mutateProfile({
                        try await appState.runtime.profileStore.toggleRule(rawLine: rule.rawLine, enabled: enabled)
                    })
                }
            }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)

        if rule.conditions != nil {
            Button {
                editingRule = rule
                showAddRule = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
        }

        Button(role: .destructive) {
            Task {
                await appState.mutateProfile({
                    try await appState.runtime.profileStore.deleteRules([rule.rawLine])
                }, successMessage: "已删除规则")
            }
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Policy Groups

    private var groupsListContent: some View {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let groups = appState.profile.groups.filter {
            query.isEmpty || $0.name.lowercased().contains(query) || $0.type.lowercased().contains(query)
        }

        return NativeCard(padding: 0) {
            if groups.isEmpty {
                CollectionEmptyState(
                    title: "暂无自定义策略分组",
                    systemImage: "folder.badge.gearshape",
                    description: "策略组可设为手选 (select)、自动测速 (url-test) 或故障切换 (fallback)，并引用订阅来源。",
                    query: query
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { idx, group in
                        let sources = (group.use + group.proxies).joined(separator: "、")
                        GroupedRow(title: group.name, subtitle: sources.isEmpty ? "无成员" : sources) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.purple)
                                .frame(width: 28, height: 28)
                                .background(Color.purple.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        } trailing: {
                            HStack(spacing: 10) {
                                StatusPill(text: group.type, tint: .purple)
                                Toggle("", isOn: Binding(
                                    get: { group.enabled },
                                    set: { enabled in
                                        Task {
                                            await appState.mutateProfile({
                                                try await appState.runtime.profileStore.toggleGroup(name: group.name, enabled: enabled)
                                            })
                                        }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)

                                Button {
                                    editingGroup = group
                                    showAddGroup = true
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)

                                Button(role: .destructive) {
                                    Task {
                                        await appState.mutateProfile({
                                            try await appState.runtime.profileStore.removeGroup(name: group.name)
                                        }, successMessage: "已删除策略组「\(group.name)」")
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        if idx < groups.count - 1 {
                            HairlineDivider(inset: 56)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Running Applications (macOS)

    #if os(macOS)
    private var processDirectory: some View {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let apps = appState.groupedApps.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.primaryPath.localizedCaseInsensitiveContains(query)
        }
        let processes = appState.runningProcesses.filter {
            query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query)
        }
        return VStack(spacing: 0) {
            if appState.hasLimitedProcessMatching {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("当前内核在 macOS 27 上可能无法匹配应用。支持代理设置的应用可通过固定端口指定节点。")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("设置固定入口…") {
                        appState.openFixedListeners = true
                        appState.selectedDestination = .nodes
                    }
                }.padding(.horizontal, 18).padding(.vertical, 9)
                Divider()
            }
            if scanByProcess && !processes.isEmpty {
                Table(processes) {
                    TableColumn("进程") { item in
                        Text(item.executable).lineLimit(1).help(item.path)
                    }
                    TableColumn("PID") { Text(String($0.pid)).monospacedDigit() }.width(66)
                    TableColumn("线程") { Text(String($0.threadCount)).monospacedDigit() }.width(46)
                    TableColumn("出口策略") { item in exitMenu(paths: [item.path], name: item.name) }.width(min: 100, ideal: 145)
                }
            } else if !scanByProcess && !apps.isEmpty {
                Table(apps) {
                    TableColumn("应用") { app in
                        HStack(spacing: 10) {
                            AppIconThumbnail(path: app.bundlePath, size: 25)
                            Text(app.name).lineLimit(1)
                        }.padding(.vertical, 3).help(app.primaryPath)
                    }
                    TableColumn("进程数") { Text(String($0.instanceCount)).monospacedDigit() }.width(65)
                    TableColumn("出口策略") { app in exitMenu(paths: app.paths, name: app.name) }.width(min: 100, ideal: 145)
                }
            } else if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if appState.scanningProcesses {
                ProgressView("正在读取本机应用…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("未读取到运行中的应用", systemImage: "macwindow")
                } description: {
                    Text("可以重新读取，也可以在分流规则中选取应用。")
                } actions: {
                    Button("重新读取") { Task { await appState.refreshProcesses() } }
                }
            }
            HStack {
                Text(scanByProcess ? "\(processes.count) 个进程" : "\(apps.count) 个应用")
                Spacer()
                if appState.scanningProcesses { ProgressView().controlSize(.mini) }
                Text("来自本机进程列表")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .alternatingRowBackgrounds(.enabled)
    }

    private func exitMenu(paths: [String], name: String) -> some View {
        Menu {
            Button("跟随默认规则") {
                Task { await appState.mutateProfile({
                    try await appState.runtime.profileStore.setProgramExits(paths: paths, exit: nil)
                }, successMessage: "已清除「\(name)」的专用规则") }
            }
            Divider()
            ForEach(appState.profile.exits, id: \.self) { exit in
                Button(exit) {
                    Task { await appState.mutateProfile({
                        try await appState.runtime.profileStore.setProgramExits(paths: paths, exit: exit)
                    }, successMessage: "「\(name)」将使用 \(exit)") }
                }
            }
        } label: { Text(currentExit(for: paths) ?? "默认规则").lineLimit(1) }
        .menuStyle(.borderlessButton)
    }
    #endif

    #if os(iOS)
    private var runningAppsContent: some View {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return NativeCard(padding: 0) {
            if !scanByProcess {
                let apps = appState.groupedApps.filter {
                    query.isEmpty || $0.name.lowercased().contains(query) || $0.primaryPath.lowercased().contains(query)
                }
                if apps.isEmpty {
                    Text("没有匹配的运行中应用")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(32)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { idx, app in
                            GroupedRow(title: app.name, subtitle: "\(app.instanceCount) 个进程 · \(app.primaryPath)") {
                                AppIconThumbnail(path: app.bundlePath ?? app.primaryPath, size: 28)
                            } trailing: {
                                Menu {
                                    Button("清除专用规则") {
                                        Task {
                                            await appState.mutateProfile({
                                                try await appState.runtime.profileStore.setProgramExits(paths: app.paths, exit: nil)
                                            }, successMessage: "已清除「\(app.name)」的规则")
                                        }
                                    }
                                    Divider()
                                    ForEach(appState.profile.exits, id: \.self) { exit in
                                        Button(exit) {
                                            Task {
                                                await appState.mutateProfile({
                                                    try await appState.runtime.profileStore.setProgramExits(paths: app.paths, exit: exit)
                                                }, successMessage: "已为「\(app.name)」设置出口：\(exit)")
                                            }
                                        }
                                    }
                                } label: {
                                    let active = currentExit(for: app.paths)
                                    StatusPill(text: active ?? "默认规则", tint: active == nil ? .secondary : .blue)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            if idx < apps.count - 1 {
                                HairlineDivider(inset: 56)
                            }
                        }
                    }
                }
            } else {
                let procs = appState.runningProcesses.filter {
                    query.isEmpty || $0.name.lowercased().contains(query) || $0.path.lowercased().contains(query) || "\($0.pid)".contains(query)
                }
                VStack(spacing: 0) {
                    ForEach(Array(procs.enumerated()), id: \.element.id) { idx, proc in
                        GroupedRow(title: "\(proc.name) (PID \(proc.pid))", subtitle: "\(proc.threadCount) 线程 · \(proc.path)") {
                            AppIconThumbnail(path: proc.path, size: 26)
                        } trailing: {
                            Menu {
                                ForEach(appState.profile.exits, id: \.self) { exit in
                                    Button(exit) {
                                        Task {
                                            await appState.mutateProfile({
                                                try await appState.runtime.profileStore.setProgramExits(paths: [proc.path], exit: exit)
                                            }, successMessage: "已为 \(proc.executable) 设置出口：\(exit)")
                                        }
                                    }
                                }
                            } label: {
                                StatusPill(text: currentExit(for: [proc.path]) ?? "设置出口", tint: .blue)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        if idx < procs.count - 1 {
                            HairlineDivider(inset: 54)
                        }
                    }
                }
            }
        }
    }

    #endif

    private func currentExit(for paths: [String]) -> String? {
        let set = Set(paths.map { RunningAppGrouper.normalizePath($0) })
        return appState.profile.rules.first {
            $0.enabled && $0.kind == "PROCESS-PATH" && set.contains(RunningAppGrouper.normalizePath($0.payload))
        }?.exit
    }

    private func iconForRule(_ rule: ProfileRule) -> String {
        switch rule.kind {
        case "PROCESS-PATH", "PROCESS-NAME": return "app.badge"
        case "DOMAIN", "DOMAIN-SUFFIX": return "globe"
        case "IP-CIDR", "IP-CIDR6": return "network"
        case "AND": return "square.stack.3d.down.right"
        default: return "arrow.triangle.branch"
        }
    }

    private func colorForRule(_ rule: ProfileRule) -> Color {
        switch rule.kind {
        case "PROCESS-PATH", "PROCESS-NAME": return .blue
        case "DOMAIN", "DOMAIN-SUFFIX": return .cyan
        case "IP-CIDR", "IP-CIDR6": return .orange
        case "AND": return .purple
        default: return .secondary
        }
    }
}

// MARK: - Rule & Group Editor Sheets

public struct RuleEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let existing: ProfileRule?
    @State private var conditions: RuleConditions
    @State private var selectedExit: String
    @State private var errorText: String?

    public init(existing: ProfileRule? = nil, prefill: RuleConditions? = nil, defaultExit: String = "AUTO") {
        self.existing = existing
        _conditions = State(initialValue: existing?.conditions ?? prefill ?? RuleConditions())
        _selectedExit = State(initialValue: existing?.exit ?? defaultExit)
    }

    private var validationHint: String? {
        do {
            _ = try RuleConditionsEngine.compile(conditions)
            return nil
        } catch RuleConditionError.emptyConditions {
            return appState.runtime.supportsProcessRouting
                ? "应用、目标地址和端口至少填一项。填写多项时须同时匹配。"
                : "目标地址和端口至少填一项。填写两项时须同时匹配。"
        } catch {
            return error.localizedDescription
        }
    }

    public var body: some View {
        NavigationStack {
            Group {
                #if os(macOS)
                VStack(alignment: .leading, spacing: 18) {
                    Label("匹配条件", systemImage: "line.3.horizontal.decrease")
                        .font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                        GridRow {
                            Text("目标地址")
                            TextField("例如 example.com 或 192.168.1.0/24", text: $conditions.target)
                                .frame(maxWidth: .infinity)
                        }
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            Toggle("包含子域名", isOn: $conditions.suffix)
                                .toggleStyle(.checkbox)
                        }
                        if appState.runtime.supportsProcessRouting {
                            GridRow {
                                Text("应用")
                                HStack {
                                    TextField("应用或可执行文件路径", text: $conditions.program)
                                    Button("选取…") { pickExecutable() }
                                }
                            }
                        }
                        GridRow {
                            Text("目标端口")
                            TextField("例如 443 或 8000-8999", text: $conditions.port)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    if appState.hasLimitedProcessMatching && !conditions.program.isEmpty {
                        Label("当前内核在 macOS 27 上可能无法匹配应用。仅按地址分流时，请清空应用条件。", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Label("出口策略", systemImage: "arrow.turn.up.right").font(.headline)
                        Spacer()
                        Picker("出口策略", selection: $selectedExit) {
                            ForEach(appState.profile.exits, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(maxWidth: 185)
                    }
                    Text(errorText ?? validationHint ?? "流量符合以上全部条件时，使用所选出口。")
                        .font(.callout).foregroundStyle(errorText == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                #else
                Form {
                    if appState.runtime.supportsProcessRouting {
                        Section("应用（可选）") {
                            TextField("可执行文件路径", text: $conditions.program)
                        }
                    }

                    Section("目标地址（可选）") {
                        TextField("域名、网址、IP 或 CIDR 网段", text: $conditions.target)
                        Toggle("包括该域名的子域名", isOn: $conditions.suffix)
                    }

                    Section("目标端口（可选）") {
                        TextField("例如 443 或 8000-8999", text: $conditions.port)
                    }

                    Section("出口策略") {
                        Picker("匹配时使用", selection: $selectedExit) {
                            ForEach(appState.profile.exits, id: \.self) { exit in
                                Text(exit).tag(exit)
                            }
                        }
                    }

                    if let validationHint {
                        Text(validationHint).font(.callout).foregroundStyle(.secondary)
                    }
                    if let errorText {
                        Section {
                            Text(errorText).foregroundStyle(.red).font(.caption)
                        }
                    }
                }
                .formStyle(.grouped)
                #endif
            }
            .navigationTitle(existing == nil ? "添加分流规则" : "编辑分流规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            do {
                                _ = try await appState.runtime.profileStore.addOrUpdateRule(
                                    editingLine: existing?.rawLine,
                                    conditions: conditions,
                                    exit: selectedExit
                                )
                                try await appState.runtime.reloadIfRunning()
                                await appState.refreshAll(fullSnapshot: true)
                                appState.notify(existing == nil ? "已添加分流规则" : "规则已更新")
                                dismiss()
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }
                    }
                    .disabled(validationHint != nil)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 410)
        #else
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }

    #if os(macOS)
    private func pickExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if url.pathExtension.lowercased() == "app",
               let bundle = Bundle(url: url),
               let execPath = bundle.executablePath
            {
                conditions.program = execPath
            } else {
                conditions.program = url.path
            }
        }
    }
    #endif
}

private struct GroupEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let existing: PolicyGroup?

    @State private var name: String
    @State private var type: String
    @State private var selectedProviders: Set<String>
    @State private var selectedProxies: Set<String>

    init(existing: PolicyGroup?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _type = State(initialValue: existing?.type ?? "select")
        _selectedProviders = State(initialValue: Set(existing?.use ?? []))
        _selectedProxies = State(initialValue: Set(existing?.proxies ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("策略组名称（例如 AI 服务）", text: $name)
                    Picker("策略类型", selection: $type) {
                        Text("手动选择 (select)").tag("select")
                        Text("自动测速 (url-test)").tag("url-test")
                        Text("故障切换 (fallback)").tag("fallback")
                    }
                }
                if !appState.profile.providers.isEmpty {
                    Section("引用订阅来源") {
                        ForEach(appState.profile.providers) { provider in
                            Toggle(provider.name, isOn: Binding(
                                get: { selectedProviders.contains(provider.name) },
                                set: { on in
                                    if on { selectedProviders.insert(provider.name) } else { selectedProviders.remove(provider.name) }
                                }
                            ))
                        }
                    }
                }
                Section("固定成员") {
                    ForEach(["AUTO", "DIRECT", "REJECT"] + appState.profile.standaloneNodes.map(\.name), id: \.self) { member in
                        Toggle(member, isOn: Binding(
                            get: { selectedProxies.contains(member) },
                            set: { on in
                                if on { selectedProxies.insert(member) } else { selectedProxies.remove(member) }
                            }
                        ))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "新建策略分组" : "编辑策略分组")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let group = PolicyGroup(
                            name: name,
                            type: type,
                            proxies: Array(selectedProxies).sorted(),
                            use: Array(selectedProviders).sorted(),
                            enabled: existing?.enabled ?? true
                        )
                        Task {
                            await appState.mutateProfile({
                                try await appState.runtime.profileStore.upsertGroup(group, originalName: existing?.name)
                            }, successMessage: "策略组「\(name)」已保存")
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
    }
}

private struct EffectiveOrderSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("首条匹配即生效（含自动局域网直连与末尾默认出口）") {
                    ForEach(Array(appState.profile.effectiveRules.enumerated()), id: \.offset) { idx, line in
                        HStack {
                            Text("\(idx + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Text(line)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("规则生效顺序")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}
