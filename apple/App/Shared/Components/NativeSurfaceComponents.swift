import SwiftUI
import XeylrouteCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Native Adaptive Card Surface

public struct NativeCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.75)
            )
    }
}

public struct SectionHeaderBar<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
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
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.red)
            } else if let ms = measurement?.delayMs {
                HStack(spacing: 4) {
                    Text("\(ms) ms")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(color(for: ms))
                    if let mbps = measurement?.mbps {
                        Text("· \(String(format: "%.1f", mbps)) Mbps")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func color(for ms: Int) -> Color {
        if ms < 100 { return .green }
        if ms < 240 { return .orange }
        return .red
    }
}

public struct StatusPill: View {
    let text: String
    let tint: Color

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

public struct CountryBadge: View {
    let nodeName: String
    let isPolicy: Bool

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(badgeTint.opacity(0.15))
                .frame(width: 28, height: 28)
            if let emoji = inferredFlag {
                Text(emoji)
                    .font(.system(size: 16))
            } else {
                Image(systemName: policyIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(badgeTint)
            }
        }
    }

    private var inferredFlag: String? {
        guard !isPolicy else { return nil }
        let lower = nodeName.lowercased()
        let pairs: [(String, String)] = [
            ("香港", "🇭🇰"), ("hk", "🇭🇰"), ("hong kong", "🇭🇰"),
            ("日本", "🇯🇵"), ("东京", "🇯🇵"), ("大阪", "🇯🇵"), ("jp", "🇯🇵"), ("tokyo", "🇯🇵"),
            ("新加坡", "🇸🇬"), ("狮城", "🇸🇬"), ("sg", "🇸🇬"), ("singapore", "🇸🇬"),
            ("美国", "🇺🇸"), ("洛杉矶", "🇺🇸"), ("硅谷", "🇺🇸"), ("us", "🇺🇸"), ("usa", "🇺🇸"),
            ("台湾", "🇹🇼"), ("台北", "🇹🇼"), ("tw", "🇹🇼"), ("taiwan", "🇹🇼"),
            ("韩国", "🇰🇷"), ("首尔", "🇰🇷"), ("kr", "🇰🇷"), ("korea", "🇰🇷"),
            ("英国", "🇬🇧"), ("伦敦", "🇬🇧"), ("uk", "🇬🇧"), ("gb", "🇬🇧"),
            ("德国", "🇩🇪"), ("法兰克福", "🇩🇪"), ("de", "🇩🇪"), ("germany", "🇩🇪"),
            ("法国", "🇫🇷"), ("fr", "🇫🇷"), ("加拿大", "🇨🇦"), ("ca", "🇨🇦"),
            ("澳大利亚", "🇦🇺"), ("au", "🇦🇺"), ("荷兰", "🇳🇱"), ("nl", "🇳🇱"),
        ]
        for (keyword, flag) in pairs where lower.contains(keyword) {
            return flag
        }
        return nil
    }

    private var policyIcon: String {
        switch nodeName.uppercased() {
        case "AUTO": return "sparkles"
        case "DIRECT": return "arrow.up.right"
        case "REJECT": return "hand.raised.fill"
        default: return "globe"
        }
    }

    private var badgeTint: Color {
        switch nodeName.uppercased() {
        case "AUTO": return .blue
        case "DIRECT": return .green
        case "REJECT": return .red
        default: return .cyan
        }
    }
}

public struct AppIconThumbnail: View {
    let path: String?

    public var body: some View {
        #if os(macOS)
        if let path, !path.isEmpty {
            let icon = NSWorkspace.shared.icon(forFile: path)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
        } else {
            fallbackIcon
        }
        #else
        fallbackIcon
        #endif
    }

    private var fallbackIcon: some View {
        Image(systemName: "app.fill")
            .font(.system(size: 16))
            .foregroundStyle(.blue)
            .frame(width: 26, height: 26)
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
