import SwiftUI
import UniformTypeIdentifiers
import XeylrouteCore

public struct SubscriptionsView: View {
    @Environment(AppState.self) private var appState

    @State private var filterText = ""
    #if os(macOS)
    @State private var expandedSources: Set<String> = []
    #endif
    @State private var showImportSheet = false
    @State private var editorTarget: EditorTarget?
    @State private var showFileImporter = false

    struct EditorTarget: Identifiable {
        let id = UUID()
        let title: String
        let providerName: String? // nil = full config, "" = new local YAML
        let isNew: Bool
    }

    public var body: some View {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let providers = appState.profile.providers.filter {
            query.isEmpty || $0.name.lowercased().contains(query) || ($0.url?.lowercased().contains(query) ?? false)
                || sourceNodes($0).contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
        let standalone = appState.profile.standaloneNodes.filter {
            query.isEmpty || $0.name.lowercased().contains(query) || $0.type.lowercased().contains(query)
        }

        return Group {
            #if os(macOS)
            if providers.isEmpty && standalone.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label("添加订阅或节点", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("从订阅地址、分享链接或本地 YAML 文件导入。")
                    } actions: {
                        Button("导入订阅或节点…") { showImportSheet = true }
                            .buttonStyle(.borderedProminent)
                        Button("打开 YAML 文件…") { showFileImporter = true }
                    }
                } else {
                    ContentUnavailableView.search(text: filterText)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !providers.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("订阅来源").font(.title2.weight(.semibold))
                                    Text("\(providers.count)").foregroundStyle(.secondary).monospacedDigit()
                                }
                                ForEach(providers) { provider in
                                    subscriptionDetails(provider)
                                        .padding(16)
                                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                                }
                            }
                        }
                        if !standalone.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("独立节点").font(.title2.weight(.semibold))
                                ForEach(standalone) { node in standaloneRow(node) }
                            }
                        }
                    }
                    .frame(maxWidth: 740, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
            }
            #else
            ScrollView {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeaderBar("订阅来源") {
                            HStack(spacing: 12) {
                                #if os(iOS)
                                InlineSearchField(text: $filterText, placeholder: "搜索订阅或节点")
                                    .frame(width: 200)
                                #endif
                                Button("编辑完整配置…") {
                                    editorTarget = EditorTarget(title: "编辑完整配置", providerName: nil, isNew: false)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            }
                        }

                        if providers.isEmpty && standalone.isEmpty && !query.isEmpty {
                            ContentUnavailableView.search(text: filterText)
                        } else if providers.isEmpty && query.isEmpty {
                            NativeCard(padding: 34) {
                                VStack(spacing: 10) {
                                    Image(systemName: "square.stack.3d.up")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.secondary)
                                    Text("还没有订阅来源")
                                        .font(.headline)
                                    Text("支持粘贴 HTTPS 订阅链接、多条分享链接（VLESS / VMess / Trojan / SS / Hysteria2 / TUIC / Base64）或导入 Clash YAML 文件。")
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                    HStack(spacing: 10) {
                                        Button("导入订阅或节点…") { showImportSheet = true }
                                            .buttonStyle(.borderedProminent)
                                        Button("导入 YAML 文件…") { showFileImporter = true }
                                            .buttonStyle(.bordered)
                                    }
                                    .padding(.top, 4)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                                ForEach(providers) { provider in
                                    subscriptionCard(provider)
                                }
                            }
                        }
                    }

                    if !standalone.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeaderBar("直接导入的独立节点") {
                                Text("共 \(standalone.count) 个")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            NativeCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(standalone.enumerated()), id: \.element.id) { idx, node in
                                        standaloneRow(node)
                                        if idx < standalone.count - 1 {
                                            HairlineDivider(inset: 52)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            #endif
        }
        .navigationTitle("订阅管理")
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .automatic) {
                WorkspaceSearch(query: $filterText, prompt: "搜索订阅或节点")
            }
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                #if os(macOS)
                Menu {
                    Button("导入 YAML 文件…") { showFileImporter = true }
                    Button("新建 YAML…") { editorTarget = EditorTarget(title: "新建本地 YAML", providerName: "", isNew: true) }
                    Button("编辑完整配置…") {
                        editorTarget = EditorTarget(title: "编辑完整配置", providerName: nil, isNew: false)
                    }
                } label: {
                    Label("配置操作", systemImage: "ellipsis.circle")
                }
                #endif
                if appState.profile.providers.filter(\.isRemote).count > 1 {
                    Button("全部刷新") {
                        Task {
                            for provider in appState.profile.providers where provider.isRemote {
                                await appState.refreshSubscription(name: provider.name)
                            }
                        }
                    }
                }
                #if os(iOS)
                Button("新建 YAML") {
                    editorTarget = EditorTarget(title: "新建本地 YAML", providerName: "", isNew: true)
                }
                #endif
                Button {
                    showImportSheet = true
                } label: {
                    Label("导入订阅或节点…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSubscriptionSheet()
                .environment(appState)
        }
        .sheet(item: $editorTarget) { target in
            YAMLDocumentSheet(title: target.title, providerName: target.providerName, isNew: target.isNew)
                .environment(appState)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.plainText, .json, .yaml, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                appState.notify("无法读取所选文件内容", isError: true)
                return
            }
            let fileName = url.lastPathComponent
            Task {
                await appState.mutateProfile({
                    try await appState.runtime.profileStore.importLocalSubscriptionYAML(name: fileName, content: text)
                }, successMessage: "已导入「\(fileName)」")
            }
        }
    }

    private func standaloneRow(_ node: ProxyNode) -> some View {
        GroupedRow(title: node.name, subtitle: "\(node.type.uppercased()) · 独立节点") {
            CountryBadge(nodeName: node.name, isPolicy: false, size: .compact)
        } trailing: {
            Button(role: .destructive) {
                Task {
                    await appState.mutateProfile({
                        try await appState.runtime.profileStore.removeStandaloneNode(name: node.name)
                    }, successMessage: "已删除节点「\(node.name)」")
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    #if os(iOS)
    private func subscriptionCard(_ provider: SubscriptionProvider) -> some View {
        NativeCard(padding: 15, highlighted: appState.profile.subscriptionScope == provider.name) {
            subscriptionDetails(provider)
        }
    }
    #endif

    private func sourceNodes(_ provider: SubscriptionProvider) -> [ProxyNode] {
        appState.snapshot?.providers[provider.name]?.nodes ?? provider.nodes
    }

    private func subscriptionDetails(_ provider: SubscriptionProvider) -> some View {
        let isSelected = appState.profile.subscriptionScope == provider.name
        let live = appState.snapshot?.providers[provider.name]
        let usage = live?.usage ?? provider.usage
        let nodes = sourceNodes(provider)
        let nodeCount = nodes.count

        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: provider.isRemote ? "icloud.and.arrow.down.fill" : "doc.text.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        (isSelected ? Color.accentColor : Color.secondary).opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if isSelected {
                            StatusPill(text: "已选用", tint: .teal)
                        }
                    }
                    Text(provider.isRemote ? "远程订阅" : "本地 YAML 订阅")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                #if os(macOS)
                sourceActions(provider, isSelected: isSelected)
                #endif
            }

            if let error = appState.subscriptionErrors[provider.name] {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let usage, usage.total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: usage.progress)
                        .tint(.blue)
                    HStack {
                        Text("\(TrafficTracker.formatBytes(usage.used)) / \(TrafficTracker.formatBytes(usage.total))")
                        Spacer()
                        if let expire = usage.expireDate {
                            Text("到期 \(expire.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }

            HairlineDivider(inset: 0)

            #if os(macOS)
            if nodes.isEmpty {
                Label(appState.refreshingProviders.contains(provider.name) ? "正在获取节点…" : "尚无可用节点",
                      systemImage: "network")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
                let matches = query.isEmpty ? [] : nodes.filter { $0.name.localizedCaseInsensitiveContains(query) }
                let expanded = expandedSources.contains(provider.name)
                if matches.isEmpty {
                    Button {
                        if expanded { expandedSources.remove(provider.name) }
                        else { expandedSources.insert(provider.name) }
                    } label: {
                        Label("\(nodeCount) 个节点", systemImage: expanded ? "chevron.down" : "chevron.right")
                    }.buttonStyle(.plain).font(.callout.weight(.medium))
                } else {
                    Text("匹配 \(matches.count) 个节点").font(.callout.weight(.medium))
                }
                if expanded || !matches.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(matches.isEmpty ? nodes : matches) { node in
                            HStack {
                                Text(node.name).lineLimit(1)
                                Spacer()
                                Text(node.type.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.leading, 16)
                }
            }
            #else
            HStack {
                Text("\(nodeCount) 个节点").font(.callout).foregroundStyle(.secondary)
                Spacer()
                sourceActions(provider, isSelected: isSelected)
            }
            #endif
        }
    }

    @ViewBuilder
    private func sourceActions(_ provider: SubscriptionProvider, isSelected: Bool) -> some View {
        if !isSelected {
            Button("切换使用") {
                Task {
                    await appState.mutateProfile({
                        try await appState.runtime.profileStore.setSubscriptionScope(provider.name)
                    }, successMessage: "已切换到订阅「\(provider.name)」")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        if provider.isRemote {
            Button {
                Task { await appState.refreshSubscription(name: provider.name) }
            } label: {
                if appState.refreshingProviders.contains(provider.name) {
                    ProgressView().controlSize(.small)
                } else {
                    Label(appState.subscriptionErrors[provider.name] == nil ? "刷新" : "重试", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(appState.refreshingProviders.contains(provider.name))
            .help("重新获取订阅节点")
        }
        Menu {
            Button("编辑 YAML…") {
                editorTarget = EditorTarget(title: "编辑订阅 · \(provider.name)", providerName: provider.name, isNew: false)
            }
            Button("移除订阅", role: .destructive) {
                Task {
                    await appState.mutateProfile({
                        try await appState.runtime.profileStore.removeProvider(name: provider.name)
                    }, successMessage: "已移除订阅「\(provider.name)」")
                }
            }
        } label: {
            Label("订阅操作", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .fixedSize()
    }
}

struct ImportSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("导入订阅或节点").font(.title2.bold())
                ConnectionSourceEditor(onClose: { dismiss() })
            }
            .padding(24)
        }
        #if os(macOS)
        .frame(width: 520, height: 370)
        #endif
    }
}

struct ConnectionSourceEditor: View {
    @Environment(AppState.self) private var appState
    var onClose: (() -> Void)?
    @State private var name = ""
    @State private var content = ""
    @State private var errorText: String?
    @State private var choosingFile = false
    @State private var importing = false

    private var trimmed: String { content.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isRemote: Bool {
        let value = trimmed.lowercased()
        return !value.contains("\n") && (value.hasPrefix("http://") || value.hasPrefix("https://"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("配置来源", systemImage: "link").font(.headline)
                Spacer()
                Button("粘贴") {
                    if let value = ClipboardHelper.read(), !value.isEmpty { content = value }
                    else { errorText = "剪贴板中没有可导入的文本。" }
                }
                Button("打开文件…") { choosingFile = true }
            }
            TextEditor(text: $content)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 76)
                .overlay(alignment: .topLeading) {
                    if content.isEmpty {
                        Text("粘贴订阅地址、节点链接或 YAML…")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(11).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.35)))
                .accessibilityLabel("链接或配置内容")
            if !trimmed.isEmpty && !ShareLinkParser.looksLikeShareLinks(trimmed) {
                TextField("名称（可选）", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("名称，可选")
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
            } else {
                Text("支持多行节点链接、Base64 和 Clash YAML。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if importing {
                    ProgressView().controlSize(.small)
                    Text(isRemote ? "正在获取订阅节点…" : "正在导入…").foregroundStyle(.secondary)
                }
                Spacer()
                if let onClose {
                    Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                }
                Button("导入") {
                    guard !importing else { return }
                    importing = true
                    Task { await performImport() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty)
            }
        }
        .disabled(importing)
        .interactiveDismissDisabled(importing)
        .onChange(of: content) { _, _ in errorText = nil }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.yaml, .json, .plainText, .data]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let source = try String(contentsOf: url, encoding: .utf8)
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errorText = "文件是空的，请选择包含节点的配置。"
                    return
                }
                content = source
                name = url.deletingPathExtension().lastPathComponent
            } catch {
                if (error as NSError).code != NSUserCancelledError { errorText = error.localizedDescription }
            }
        }
    }

    private func performImport() async {
        defer { importing = false }
        errorText = nil
        let store = appState.runtime.profileStore
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let message: String
            if isRemote {
                let added = try await store.createRemoteSubscription(name: title, urlString: trimmed)
                appState.profile = await store.summary()
                do {
                    try await appState.fetchSubscription(name: added)
                } catch {
                    await appState.refreshAll(fullSnapshot: true)
                    appState.selectedDestination = .subscriptions
                    appState.notify("已保存「\(added)」，获取节点失败。请在订阅中点「重试」。\(error.localizedDescription)", isError: true)
                    onClose?()
                    return
                }
                message = "已导入订阅「\(added)」"
            } else {
                if ShareLinkParser.looksLikeShareLinks(trimmed) {
                    let (_, count) = try await store.importShareLinks(trimmed)
                    message = "已导入 \(count) 个节点"
                } else {
                    _ = try await store.importLocalSubscriptionYAML(name: title.isEmpty ? "导入配置" : title, content: trimmed)
                    message = "已导入本地配置"
                }
                do { try await appState.runtime.reloadIfRunning() }
                catch {
                    await appState.refreshAll(fullSnapshot: true)
                    appState.notify("\(message)，重新加载失败：\(error.localizedDescription)", isError: true)
                    onClose?()
                    return
                }
            }
            await appState.refreshAll(fullSnapshot: true)
            appState.notify(message)
            onClose?()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct YAMLDocumentSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let title: String
    let providerName: String?
    let isNew: Bool

    @State private var fileName = "自建订阅.yaml"
    @State private var text = ""
    @State private var errorText: String?

    private static let newTemplate = """
    # 将示例地址和端口替换为自己的代理服务
    proxies:
      - name: 我的代理
        type: socks5
        server: 127.0.0.1
        port: 1080
    """

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if isNew {
                    HStack {
                        Text("文件名").font(.subheadline)
                        TextField("自建订阅.yaml", text: $fileName)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 12)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "创建" : "保存") {
                        Task {
                            do {
                                if isNew {
                                    _ = try await appState.runtime.profileStore.importLocalSubscriptionYAML(name: fileName, content: text)
                                } else if let providerName {
                                    try await appState.runtime.profileStore.saveProviderPayload(name: providerName, yamlContent: text)
                                } else {
                                    _ = try await appState.runtime.profileStore.importFullConfig(content: text)
                                }
                                try? await appState.runtime.reloadIfRunning()
                                await appState.refreshAll(fullSnapshot: true)
                                appState.notify(isNew ? "已创建本地 YAML 订阅" : "配置已保存")
                                dismiss()
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .task {
                if isNew {
                    text = Self.newTemplate
                } else {
                    text = (try? await appState.runtime.profileStore.readDocument(providerName: providerName)) ?? ""
                }
            }
        }
        .frame(minWidth: 620, minHeight: 500)
    }
}
