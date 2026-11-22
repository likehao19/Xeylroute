import SwiftUI
import XeylrouteCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

extension View {
    func workspaceTitle(_ page: AppDestination) -> some View {
        #if os(macOS)
        self
        #else
        navigationTitle(page.title)
        #endif
    }

    func workspaceToolbarPrimary() -> some View {
        #if os(macOS)
        buttonStyle(.automatic)
        #else
        buttonStyle(.borderedProminent)
        #endif
    }

    func workspaceControlBar() -> some View {
        #if os(macOS)
        self.padding(.horizontal, 20)
            .controlSize(.small)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
        #else
        self.padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)
        #endif
    }
}

#if os(macOS)
extension View {
    func macPanel(radius: CGFloat = 9, selected: Bool = false) -> some View {
        modifier(WorkspacePanel(radius: radius, selected: selected))
    }

    func macTableSurface() -> some View {
        self.scrollContentBackground(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .macPanel(radius: 8)
            .padding(.horizontal, 20).padding(.vertical, 16)
    }
}

private struct WorkspacePanel: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let radius: CGFloat
    let selected: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        let surface = dark ? Color(white: 0.175) : Color(white: 0.995)
        return content
            .background(surface, in: shape)
            .overlay {
                shape.strokeBorder(selected ? Color.accentColor : (dark ? .white.opacity(0.09) : .black.opacity(0.10)),
                                   lineWidth: selected ? 1.5 : 0.6)
                    .allowsHitTesting(false)
            }
    }
}

struct WorkspaceMetric: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkspaceSearch: View {
    @Binding var query: String
    let prompt: String
    @State private var expanded = false
    @FocusState private var focused: Bool

    var body: some View {
        if expanded || !query.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(prompt, text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .accessibilityLabel(prompt)
                    .onExitCommand { close() }
                Button(action: close) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("关闭搜索")
            }
            .frame(width: 182)
            .padding(.horizontal, 5)
            .onAppear { focused = true }
        } else {
            Button {
                expanded = true
            } label: {
                Label(prompt, systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f")
            .help(prompt)
        }
    }

    private func close() {
        query = ""
        expanded = false
        focused = false
    }
}

struct WorkspacePlaceholder: View {
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 29, weight: .light))
                .foregroundStyle(.secondary).accessibilityHidden(true).padding(.bottom, 3)
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 340)
            Button(actionTitle, action: action).padding(.top, 5)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WorkspaceNodeList: View {
    @Environment(AppState.self) private var appState
    let nodes: [ProxyNode]
    var selectedName: String?
    var select: ((ProxyNode) -> Void)?

    var body: some View {
        LazyVStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("节点名称")
                Spacer()
                Text("协议").frame(width: 78, alignment: .leading)
                if select != nil { Text("延迟").frame(width: 72, alignment: .trailing) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 14).frame(height: 29)
            .background(Color.primary.opacity(0.035))
            ForEach(nodes) { node in
                Divider()
                HStack(spacing: 12) {
                    if let select {
                        Button { select(node) } label: { nodeLabel(node) }
                            .buttonStyle(.plain).help("使用 " + node.name)
                        Button {
                            Task { await appState.measureDelay(for: node) }
                        } label: {
                            if appState.nodeDelays[node.id] != nil || appState.testingNodes.contains(node.id) {
                                LatencyBadge(measurement: appState.nodeDelays[node.id], isTesting: appState.testingNodes.contains(node.id))
                            } else {
                                Text("测速").font(.callout)
                            }
                        }
                        .buttonStyle(.borderless).disabled(appState.testingNodes.contains(node.id))
                        .frame(width: 72, alignment: .trailing)
                        .accessibilityLabel("测试" + node.name + "的延迟")
                    } else {
                        nodeLabel(node)
                    }
                }
                .padding(.horizontal, 14)
                .background(node.name == selectedName ? Color.accentColor.opacity(0.10) : .clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9)).macPanel()
    }

    private func nodeLabel(_ node: ProxyNode) -> some View {
        HStack(spacing: 8) {
            CountryBadge(nodeName: node.name, isPolicy: node.isPolicy)
            Text(node.displayName).lineLimit(1).truncationMode(.middle)
            if node.name == selectedName {
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.tint)
            }
            Spacer(minLength: 4)
            Text(node.type.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
        }
        .frame(minHeight: 34).contentShape(Rectangle()).help(node.name)
    }
}

struct SubscriptionNotes: View {
    let notes: [ProxyNode]
    let searching: Bool
    @State private var expanded = false

    var body: some View {
        if !notes.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(notes) { Text($0.name).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
            } label: {
                Text("订阅说明（\(notes.count)）")
            }
            .font(.callout).foregroundStyle(.secondary)
            .onChange(of: searching, initial: true) { _, value in expanded = value }
        }
    }
}
#endif

public struct SectionHeaderBar<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                #if os(macOS)
                .font(.headline)
                .foregroundStyle(.primary)
                #else
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                #endif
            Spacer()
            trailing
        }
        .padding(.horizontal, 6)
    }
}

struct CollectionEmptyState: View {
    let title: String
    let systemImage: String
    let description: String
    let query: String

    var body: some View {
        #if os(macOS)
        if query.isEmpty {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(description)
            }
            .padding(.vertical, 28)
        } else {
            ContentUnavailableView.search(text: query)
                .padding(.vertical, 28)
        }
        #else
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(36)
        #endif
    }
}

public struct LatencyBadge: View {
    let measurement: DelayMeasurement?
    let isTesting: Bool

    public var body: some View {
        Group {
            if isTesting {
                ProgressView()
                    .controlSize(.mini)
            } else if let err = measurement?.error {
                Text(err)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.red)
            } else if let measurement, measurement.delayMs != nil || measurement.mbps != nil {
                HStack(spacing: 4) {
                    if let ms = measurement.delayMs {
                        Text("\(ms) ms")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(color(for: ms))
                    }
                    if let mbps = measurement.mbps {
                        Text("\(mbps, specifier: "%.1f") Mbps")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
            } else {
                Text("—")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func color(for ms: Int) -> Color {
        if ms < 100 { return .green }
        if ms < 220 { return .orange }
        return .red
    }
}

public struct StatusPill: View {
    let text: String
    let tint: Color
    let showDot: Bool

    public init(text: String, tint: Color, showDot: Bool = false) {
        self.text = text
        self.tint = tint
        self.showDot = showDot
    }

    public var body: some View {
        HStack(spacing: 5) {
            if showDot {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(tint.opacity(0.13), in: Capsule())
        .foregroundStyle(tint)
    }
}

public struct AppIconThumbnail: View {
    let path: String?
    let size: CGFloat

    public init(path: String?, size: CGFloat = 26) {
        self.path = path
        self.size = size
    }

    public var body: some View {
        #if os(macOS)
        if let path, !path.isEmpty {
            let icon = NSWorkspace.shared.icon(forFile: path)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            fallbackIcon
        }
        #else
        fallbackIcon
        #endif
    }

    private var fallbackIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
            Image(systemName: "app.fill")
                .font(.system(size: size * 0.5))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: size, height: size)
    }
}

public enum ClipboardHelper {
    public static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    public static func read() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string
        #endif
    }
}

public func formatDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}
