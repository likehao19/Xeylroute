import SwiftUI
import XeylrouteCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

extension View {
    func workspaceControlBar() -> some View {
        #if os(macOS)
        self.padding(.horizontal, 24)
            .padding(.bottom, 12)
            .padding(.top, 2)
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
    func macPanel() -> some View {
        self.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.09)))
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

/// A route preview for pages where the user has not added any entries yet.
struct RouteSetupPanel: View {
    let title: String
    let detail: String
    let source: String
    let destination: String
    let sourceIcon: String
    let destinationIcon: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                endpoint(source, icon: sourceIcon)
                Rectangle().fill(.teal.opacity(0.35)).frame(height: 1)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.teal)
                endpoint(destination, icon: destinationIcon)
            }
            .padding(24)
            .background(LinearGradient(colors: [.teal.opacity(0.13), .indigo.opacity(0.07)], startPoint: .leading, endPoint: .trailing))
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title2.weight(.semibold))
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent).padding(.top, 5)
            }
            .padding(24)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 15))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.separator))
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 36)
    }

    private func endpoint(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
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
