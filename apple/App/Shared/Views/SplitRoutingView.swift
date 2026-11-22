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
        case apps = "运行中的程序"
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
                .frame(maxWidth: 320)

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
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)

            #if os(macOS)
            if selectedTab == .rules {
                Divider()
                rulesListContent
            } else {
                tabContent
            }
            #else
            tabContent
            #endif
        }
        .navigationTitle("分流与程序")
        #if os(macOS)
        .searchable(text: $filterText, placement: .toolbar, prompt: selectedTab == .apps ? "搜索应用或路径" : "搜索规则或分组")
        #endif
        .toolbar {
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
                    .buttonStyle(.borderedProminent)
                } else if selectedTab == .groups {
                    Button {
                        editingGroup = nil
                        showAddGroup = true
                    } label: {
                        Label("新建分组", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
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
                    runningAppsContent
                }
            }
            .padding(20)
        }
    }

    // MARK: - Rules

    private var rulesListContent: some View {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = appState.profile.rules.filter { rule in
            !rule.isDefaultMatch && (query.isEmpty || rule.rawLine.lowercased().contains(query))
        }

        #if os(macOS)
        return Table(items, selection: $selectedRule) {
            TableColumn("匹配条件") { rule in
                Label(rule.payload.isEmpty ? rule.kind : rule.payload, systemImage: iconForRule(rule))
            }
            TableColumn("类型", value: \.kind).width(ideal: 105)
            TableColumn("出口", value: \.exit).width(ideal: 82)
            TableColumn("操作") { rule in
                HStack(spacing: 10) { ruleControls(rule) }
            }
            .width(106)
        }
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if items.isEmpty {
                CollectionEmptyState(title: "暂无分流规则", systemImage: "arrow.triangle.branch",
                                     description: "添加规则，为应用或目标地址指定出口。", query: query)
            }
        }
        #else
        return NativeCard(padding: 0) {
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

    public var body: some View {
        NavigationStack {
            Form {
                if appState.runtime.supportsProcessRouting {
                    Section("程序路径（可选）") {
                        HStack {
                            TextField("/Applications/.../MacOS/...", text: $conditions.program)
                            #if os(macOS)
                            Button("选择…") {
                                pickExecutable()
                            }
                            #endif
                        }
                    }
                }

                Section("目标地址（可选）") {
                    TextField("域名、网址、IP 或 CIDR 网段", text: $conditions.target)
                    Toggle("同时匹配所有子域名 (DOMAIN-SUFFIX)", isOn: $conditions.suffix)
                }

                Section("目标端口（可选）") {
                    TextField("例如 443 或 8000-8999", text: $conditions.port)
                }

                Section("出口策略") {
                    Picker("命中后走", selection: $selectedExit) {
                        ForEach(appState.profile.exits, id: \.self) { exit in
                            Text(exit).tag(exit)
                        }
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
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
                                try? await appState.runtime.reloadIfRunning()
                                await appState.refreshAll(fullSnapshot: true)
                                appState.notify(existing == nil ? "已添加分流规则" : "规则已更新")
                                dismiss()
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 380)
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
