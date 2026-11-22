import SwiftUI
import XeylrouteCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
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
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 6)
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
            } else if let ms = measurement?.delayMs {
                HStack(spacing: 3) {
                    Text("\(ms)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color(for: ms))
                    Text("ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(color(for: ms).opacity(0.75))
                    if let mbps = measurement?.mbps {
                        Text("· \(String(format: "%.0f", mbps))M")
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
