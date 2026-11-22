import SwiftUI
#if os(macOS)
import XeylrouteCore
#endif

// MARK: - Calibrated Apple Graphite / Alabaster Design Tokens

public struct XeylPalette {
    public let colorScheme: ColorScheme

    public init(_ colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    public var isDark: Bool { colorScheme == .dark }

    /// Main stage canvas behind cards
    public var canvasBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        isDark ? Color(red: 0.095, green: 0.098, blue: 0.110) : Color(red: 0.942, green: 0.948, blue: 0.962)
        #endif
    }

    /// Subtle ambient top-left skylight over canvas
    public var canvasHighlight: Color {
        isDark ? Color.white.opacity(0.032) : Color.white.opacity(0.65)
    }

    /// Elevated card surface — clearly stepped above canvas
    public var cardSurface: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        isDark ? Color(red: 0.138, green: 0.142, blue: 0.158) : Color.white
        #endif
    }

    /// Secondary inner tile / node pill surface
    public var tileSurface: Color {
        #if os(macOS)
        Color.primary.opacity(0.04)
        #else
        isDark ? Color(red: 0.172, green: 0.178, blue: 0.198) : Color(red: 0.962, green: 0.966, blue: 0.976)
        #endif
    }

    public var tileHover: Color {
        isDark ? Color(red: 0.205, green: 0.212, blue: 0.236) : Color(red: 0.930, green: 0.938, blue: 0.955)
    }

    /// Recessed well (search bar, progress track, port chips)
    public var wellSurface: Color {
        isDark ? Color.black.opacity(0.28) : Color.black.opacity(0.048)
    }

    /// Crisp 0.5–1pt structural hairlines
    public var cardBorder: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        isDark ? Color.white.opacity(0.085) : Color.black.opacity(0.075)
        #endif
    }

    public var cardTopSpecular: Color {
        isDark ? Color.white.opacity(0.11) : Color.white.opacity(0.95)
    }

    public var tileBorder: Color {
        isDark ? Color.white.opacity(0.065) : Color.black.opacity(0.055)
    }

    public var divider: Color {
        isDark ? Color.white.opacity(0.075) : Color.black.opacity(0.068)
    }

    public var cardShadowColor: Color {
        isDark ? Color.black.opacity(0.32) : Color.black.opacity(0.055)
    }

    public var rowHover: Color {
        isDark ? Color.white.opacity(0.045) : Color.black.opacity(0.028)
    }

    public var selectedFill: Color {
        isDark ? Color.accentColor.opacity(0.16) : Color.accentColor.opacity(0.085)
    }

    public var selectedBorder: Color {
        isDark ? Color.accentColor.opacity(0.62) : Color.accentColor.opacity(0.48)
    }
}

// MARK: - Stage Canvas Container

public struct StageCanvas<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let palette = XeylPalette(colorScheme)
        ZStack {
            palette.canvasBackground.ignoresSafeArea()
            #if os(iOS)
            RadialGradient(
                colors: [palette.canvasHighlight, .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 680
            )
            .ignoresSafeArea()
            #endif
            content
        }
    }
}

// MARK: - Elevated Native Card

public struct NativeCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let padding: CGFloat
    private let radius: CGFloat
    private let highlighted: Bool
    private let content: Content

    public init(
        padding: CGFloat = 16,
        radius: CGFloat = 14,
        highlighted: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.radius = radius
        self.highlighted = highlighted
        self.content = content()
    }

    public var body: some View {
        #if os(macOS)
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .macPanel(radius: radius, selected: highlighted)
        #else
        let palette = XeylPalette(colorScheme)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.cardSurface, in: shape)
            .overlay(
                shape.strokeBorder(
                    highlighted ? palette.selectedBorder : palette.cardBorder,
                    lineWidth: highlighted ? 1.25 : 0.75
                )
            )
            .overlay(alignment: .top) {
                if palette.isDark {
                    shape
                        .stroke(
                            LinearGradient(
                                colors: [palette.cardTopSpecular, .clear],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: 0.75
                        )
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: palette.cardShadowColor, radius: palette.isDark ? 12 : 8, x: 0, y: palette.isDark ? 5 : 2)
        #endif
    }
}

// MARK: - Grouped List Row (Unified Settings / App / Rule Row)

public struct GroupedRow<Leading: View, Trailing: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private let title: String
    private let subtitle: String?
    private let leading: Leading
    private let trailing: Trailing

    public init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        let palette = XeylPalette(colorScheme)
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(isHovering ? palette.rowHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

public struct HairlineDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    private let inset: CGFloat

    public init(inset: CGFloat = 16) {
        self.inset = inset
    }

    public var body: some View {
        XeylPalette(colorScheme).divider
            .frame(height: 0.5)
            .padding(.leading, inset)
            .padding(.trailing, 16)
    }
}

// MARK: - Inline Search Capsule

public struct InlineSearchField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    let placeholder: String

    public init(text: Binding<String>, placeholder: String) {
        self._text = text
        self.placeholder = placeholder
    }

    public var body: some View {
        let palette = XeylPalette(colorScheme)
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(palette.wellSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.tileBorder, lineWidth: 0.75)
        )
    }
}

// MARK: - Progressive Liquid Glass Modifier (macOS 26/27 & iOS 26/27)

public struct FloatingGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    public func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            let palette = XeylPalette(colorScheme)
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(palette.cardBorder, lineWidth: 0.75))
                .shadow(color: palette.cardShadowColor, radius: 14, y: 6)
        }
    }
}

public extension View {
    func floatingGlass<S: InsettableShape>(in shape: S) -> some View {
        modifier(FloatingGlassModifier(shape: shape))
    }
}

// MARK: - Crisp Vector Rounded-Rect Country Flags (No Blurry Emoji Boxes!)

public struct CountryBadge: View {
    public enum Size {
        case compact // 24 × 17
        case large   // 36 × 25

        var width: CGFloat { self == .compact ? 24 : 36 }
        var height: CGFloat { self == .compact ? 17 : 25 }
        var radius: CGFloat { self == .compact ? 4 : 6 }
    }

    let nodeName: String
    let isPolicy: Bool
    let size: Size

    public init(nodeName: String, isPolicy: Bool, size: Size = .compact) {
        self.nodeName = nodeName
        self.isPolicy = isPolicy
        self.size = size
    }

    public var body: some View {
        #if os(macOS)
        Group {
            if isPolicy {
                let symbol = ["DIRECT": "arrow.up.right", "REJECT": "hand.raised", "AUTO": "sparkles"][nodeName] ?? "arrow.triangle.branch"
                Image(systemName: symbol).foregroundStyle(.tint)
            } else if let flag = ProxyNode.leadingFlag(in: nodeName) {
                Text(String(flag))
            } else if let code = inferredCountryCode {
                Text(code.unicodeScalars.compactMap { UnicodeScalar($0.value + 127397).map(String.init) }.joined())
            } else {
                Image(systemName: "globe").foregroundStyle(.secondary)
            }
        }.font(.system(size: size == .large ? 24 : 16))
            .frame(width: size.width, height: size.height).accessibilityHidden(true)
        #else
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        Group {
            if isPolicy {
                policyBadge(shape: shape)
            } else if let code = inferredCountryCode {
                vectorFlag(code: code, shape: shape)
            } else {
                genericGlobe(shape: shape)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.16), radius: 2, x: 0, y: 1)
        #endif
    }

    @ViewBuilder
    private func policyBadge(shape: RoundedRectangle) -> some View {
        let upper = nodeName.uppercased()
        let (tint, icon): (Color, String) = {
            switch upper {
            case "AUTO": return (.blue, "sparkles")
            case "DIRECT": return (.green, "arrow.up.right")
            case "REJECT": return (.red, "hand.raised.fill")
            default: return (.indigo, "point.3.connected.trianglepath.dotted")
            }
        }()
        ZStack {
            LinearGradient(
                colors: [tint.opacity(0.95), tint.opacity(0.75)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: icon)
                .font(.system(size: size == .compact ? 9.5 : 13, weight: .bold))
                .foregroundStyle(.white)
        }
        .clipShape(shape)
    }

    private func genericGlobe(shape: RoundedRectangle) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.24, green: 0.44, blue: 0.72), Color(red: 0.16, green: 0.30, blue: 0.56)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "globe")
                .font(.system(size: size == .compact ? 10 : 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .clipShape(shape)
    }

    private func vectorFlag(code: String, shape: RoundedRectangle) -> some View {
        Canvas { ctx, sz in
            let rect = CGRect(origin: .zero, size: sz)
            switch code {
            case "JP":
                ctx.fill(Path(rect), with: .color(.white))
                let r = min(sz.width, sz.height) * 0.30
                ctx.fill(Path(ellipseIn: CGRect(x: sz.width / 2 - r, y: sz.height / 2 - r, width: r * 2, height: r * 2)),
                         with: .color(Color(red: 0.74, green: 0.0, blue: 0.18)))
            case "HK":
                ctx.fill(Path(rect), with: .color(Color(red: 0.85, green: 0.11, blue: 0.17)))
                let r = min(sz.width, sz.height) * 0.22
                for i in 0..<5 {
                    let angle = Double(i) * (.pi * 2 / 5) - .pi / 2
                    let cx = sz.width / 2 + cos(angle) * r * 0.65
                    let cy = sz.height / 2 + sin(angle) * r * 0.65
                    let pr = r * 0.52
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - pr, y: cy - pr, width: pr * 2, height: pr * 2)),
                             with: .color(.white.opacity(0.94)))
                }
            case "SG":
                ctx.fill(Path(CGRect(x: 0, y: 0, width: sz.width, height: sz.height / 2)),
                         with: .color(Color(red: 0.93, green: 0.16, blue: 0.22)))
                ctx.fill(Path(CGRect(x: 0, y: sz.height / 2, width: sz.width, height: sz.height / 2)),
                         with: .color(.white))
                let cr = sz.height * 0.18
                ctx.fill(Path(ellipseIn: CGRect(x: sz.width * 0.18, y: sz.height * 0.07, width: cr * 2, height: cr * 2)),
                         with: .color(.white))
                ctx.fill(Path(ellipseIn: CGRect(x: sz.width * 0.23, y: sz.height * 0.07, width: cr * 2, height: cr * 2)),
                         with: .color(Color(red: 0.93, green: 0.16, blue: 0.22)))
            case "US":
                ctx.fill(Path(rect), with: .color(.white))
                let stripeH = sz.height / 7
                for i in stride(from: 0, to: 7, by: 2) {
                    ctx.fill(Path(CGRect(x: 0, y: CGFloat(i) * stripeH, width: sz.width, height: stripeH)),
                             with: .color(Color(red: 0.70, green: 0.13, blue: 0.20)))
                }
                ctx.fill(Path(CGRect(x: 0, y: 0, width: sz.width * 0.44, height: sz.height * 0.56)),
                         with: .color(Color(red: 0.16, green: 0.23, blue: 0.48)))
            case "DE":
                let h = sz.height / 3
                ctx.fill(Path(CGRect(x: 0, y: 0, width: sz.width, height: h)), with: .color(Color(red: 0.10, green: 0.10, blue: 0.12)))
                ctx.fill(Path(CGRect(x: 0, y: h, width: sz.width, height: h)), with: .color(Color(red: 0.82, green: 0.08, blue: 0.12)))
                ctx.fill(Path(CGRect(x: 0, y: h * 2, width: sz.width, height: h)), with: .color(Color(red: 0.98, green: 0.80, blue: 0.08)))
            case "FR":
                let w = sz.width / 3
                ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: sz.height)), with: .color(Color(red: 0.0, green: 0.15, blue: 0.58)))
                ctx.fill(Path(CGRect(x: w, y: 0, width: w, height: sz.height)), with: .color(.white))
                ctx.fill(Path(CGRect(x: w * 2, y: 0, width: w, height: sz.height)), with: .color(Color(red: 0.90, green: 0.16, blue: 0.22)))
            case "NL":
                let h = sz.height / 3
                ctx.fill(Path(CGRect(x: 0, y: 0, width: sz.width, height: h)), with: .color(Color(red: 0.68, green: 0.11, blue: 0.16)))
                ctx.fill(Path(CGRect(x: 0, y: h, width: sz.width, height: h)), with: .color(.white))
                ctx.fill(Path(CGRect(x: 0, y: h * 2, width: sz.width, height: h)), with: .color(Color(red: 0.13, green: 0.27, blue: 0.55)))
            case "GB":
                ctx.fill(Path(rect), with: .color(Color(red: 0.01, green: 0.14, blue: 0.49)))
                let cw = sz.height * 0.28
                let rw = sz.height * 0.16
                ctx.fill(Path(CGRect(x: 0, y: (sz.height - cw) / 2, width: sz.width, height: cw)), with: .color(.white))
                ctx.fill(Path(CGRect(x: (sz.width - cw) / 2, y: 0, width: cw, height: sz.height)), with: .color(.white))
                ctx.fill(Path(CGRect(x: 0, y: (sz.height - rw) / 2, width: sz.width, height: rw)), with: .color(Color(red: 0.78, green: 0.06, blue: 0.18)))
                ctx.fill(Path(CGRect(x: (sz.width - rw) / 2, y: 0, width: rw, height: sz.height)), with: .color(Color(red: 0.78, green: 0.06, blue: 0.18)))
            case "KR":
                ctx.fill(Path(rect), with: .color(.white))
                let r = min(sz.width, sz.height) * 0.27
                ctx.fill(Path(ellipseIn: CGRect(x: sz.width / 2 - r, y: sz.height / 2 - r, width: r * 2, height: r * 2)),
                         with: .color(Color(red: 0.80, green: 0.13, blue: 0.22)))
                ctx.fill(Path(CGRect(x: sz.width / 2 - r, y: sz.height / 2, width: r * 2, height: r)),
                         with: .color(Color(red: 0.0, green: 0.28, blue: 0.63)))
            case "TW":
                ctx.fill(Path(rect), with: .color(Color(red: 0.90, green: 0.07, blue: 0.15)))
                ctx.fill(Path(CGRect(x: 0, y: 0, width: sz.width * 0.5, height: sz.height * 0.52)),
                         with: .color(Color(red: 0.0, green: 0.0, blue: 0.58)))
                let r = sz.height * 0.14
                ctx.fill(Path(ellipseIn: CGRect(x: sz.width * 0.25 - r, y: sz.height * 0.26 - r, width: r * 2, height: r * 2)),
                         with: .color(.white))
            case "CA":
                ctx.fill(Path(rect), with: .color(.white))
                ctx.fill(Path(CGRect(x: 0, y: 0, width: sz.width * 0.25, height: sz.height)), with: .color(Color(red: 0.85, green: 0.08, blue: 0.12)))
                ctx.fill(Path(CGRect(x: sz.width * 0.75, y: 0, width: sz.width * 0.25, height: sz.height)), with: .color(Color(red: 0.85, green: 0.08, blue: 0.12)))
                let r = sz.height * 0.18
                ctx.fill(Path(ellipseIn: CGRect(x: sz.width / 2 - r, y: sz.height / 2 - r, width: r * 2, height: r * 2)),
                         with: .color(Color(red: 0.85, green: 0.08, blue: 0.12)))
            case "CN":
                ctx.fill(Path(rect), with: .color(Color(red: 0.87, green: 0.14, blue: 0.10)))
                let r = sz.height * 0.16
                ctx.fill(Path(ellipseIn: CGRect(x: sz.width * 0.16, y: sz.height * 0.18, width: r * 2, height: r * 2)),
                         with: .color(Color(red: 1.0, green: 0.87, blue: 0.0)))
            default:
                ctx.fill(Path(rect), with: .color(.blue))
            }
        }
        .clipShape(shape)
    }

    private var inferredCountryCode: String? {
        let lower = nodeName.lowercased()
        let pairs: [(String, String)] = [
            ("香港", "HK"), ("hk", "HK"), ("hong kong", "HK"),
            ("日本", "JP"), ("东京", "JP"), ("大阪", "JP"), ("jp", "JP"), ("tokyo", "JP"),
            ("新加坡", "SG"), ("狮城", "SG"), ("sg", "SG"), ("singapore", "SG"),
            ("美国", "US"), ("洛杉矶", "US"), ("硅谷", "US"), ("us", "US"), ("usa", "US"),
            ("台湾", "TW"), ("台北", "TW"), ("tw", "TW"), ("taiwan", "TW"),
            ("韩国", "KR"), ("首尔", "KR"), ("kr", "KR"), ("korea", "KR"),
            ("英国", "GB"), ("伦敦", "GB"), ("uk", "GB"), ("gb", "GB"),
            ("德国", "DE"), ("法兰克福", "DE"), ("de", "DE"), ("germany", "DE"),
            ("法国", "FR"), ("fr", "FR"),
            ("荷兰", "NL"), ("nl", "NL"),
            ("加拿大", "CA"), ("ca", "CA"),
            ("中国", "CN"), ("国内", "CN"), ("cn", "CN"),
        ]
        let tokens = Set(lower.components(separatedBy: CharacterSet.letters.inverted))
        for (keyword, code) in pairs where keyword.count == 2 && keyword.allSatisfy(\.isASCII)
            ? tokens.contains(keyword) : lower.contains(keyword) {
            return code
        }
        return nil
    }
}
