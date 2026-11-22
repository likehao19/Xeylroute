import SwiftUI
import UniformTypeIdentifiers
import XeylrouteCore

public struct SubscriptionsView: View {
    @Environment(AppState.self) private var appState

    @State private var filterText = ""
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
        }
        let standalone = appState.profile.standaloneNodes.filter {
            query.isEmpty || $0.name.lowercased().contains(query) || $0.type.lowercased().contains(query)
        }

        return ScrollView {
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeaderBar("订阅来源") {
                        HStack(spacing: 12) {
                            InlineSearchField(text: $filterText, placeholder: "搜索订阅或节点")
                                .frame(width: 200)
                            Button("编辑完整配置…") {
                                editorTarget = EditorTarget(title: "编辑完整配置", providerName: nil, isNew: false)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        }
                    }

                    if providers.isEmpty {
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
        .navigationTitle("订阅管理")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !appState.profile.providers.isEmpty {
                    Button("全部刷新") {
                        Task {
                            for provider in appState.profile.providers where provider.isRemote {
                                await appState.refreshSubscription(name: provider.name)
                            }
                        }
                    }
                }
                Button("新建 YAML") {
                    editorTarget = EditorTarget(title: "新建本地 YAML", providerName: "", isNew: true)
                }
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

    private func subscriptionCard(_ provider: SubscriptionProvider) -> some View {
        let isSelected = appState.profile.subscriptionScope == provider.name
        let live = appState.snapshot?.providers[provider.name]
        let usage = live?.usage ?? provider.usage
        let nodeCount = live?.nodes.count ?? provider.nodes.count

        return NativeCard(padding: 15, highlighted: isSelected) {
            VStack(alignment: .leading, spacing: 11) {
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
                                StatusPill(text: "当前使用", tint: .blue)
                            }
                        }
                        Text(provider.isRemote ? (provider.url ?? "远程订阅") : "本地 YAML 订阅")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
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

                HStack {
                    Text("\(nodeCount) 个节点")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
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
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("刷新订阅")
                    }
                    Button {
                        editorTarget = EditorTarget(title: "编辑订阅 · \(provider.name)", providerName: provider.name, isNew: false)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("编辑 YAML")

                    Button(role: .destructive) {
                        Task {
                            await appState.mutateProfile({
                                try await appState.runtime.profileStore.removeProvider(name: provider.name)
                            }, successMessage: "已移除订阅「\(provider.name)」")
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct ImportSubscriptionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var content = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅名称（仅添加 HTTPS 链接时可选）") {
                    TextField("留空将自动使用订阅域名", text: $name)
                }
                Section {
                    TextEditor(text: $content)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                } header: {
                    HStack {
                        Text("粘贴 HTTPS 订阅地址、节点分享链接、Base64 或 YAML")
                        Spacer()
                        Button("从剪贴板粘贴") {
                            if let clip = ClipboardHelper.read() {
                                content = clip
                            }
                        }
                        .font(.caption)
                    }
                }
                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("导入订阅或节点")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        performImport()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 380)
    }

    private func performImport() {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://"),
                   !trimmed.contains("\n")
                {
                    let summary = try await appState.runtime.profileStore.addRemoteSubscription(
                        name: name.isEmpty ? nil : name,
                        urlString: trimmed
                    )
                    appState.profile = summary
                    if let added = summary.providers.last?.name {
                        await appState.refreshSubscription(name: added)
                    }
                    try? await appState.runtime.reloadIfRunning()
                    await appState.refreshAll(fullSnapshot: true)
                    appState.notify("已添加远程订阅")
                } else if ShareLinkParser.looksLikeShareLinks(trimmed) {
                    let (_, count) = try await appState.runtime.profileStore.importShareLinks(trimmed)
                    try? await appState.runtime.reloadIfRunning()
                    await appState.refreshAll(fullSnapshot: true)
                    appState.notify("已导入 \(count) 个代理节点")
                } else {
                    _ = try await appState.runtime.profileStore.importLocalSubscriptionYAML(
                        name: name.isEmpty ? "导入配置" : name,
                        content: trimmed
                    )
                    try? await appState.runtime.reloadIfRunning()
                    await appState.refreshAll(fullSnapshot: true)
                    appState.notify("已导入本地 YAML 订阅")
                }
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
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
