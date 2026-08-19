import AppKit
import SwiftUI

public enum DashSkin {
    private static var themeName: String {
        SharedDefaults.store.string(forKey: AppStorageKeys.General.theme) ?? "accent"
    }

    private static func shifted(_ color: Color, toward target: NSColor, by fraction: CGFloat)
        -> Color
    {
        let base = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return Color(base.blended(withFraction: fraction, of: target) ?? base)
    }

    private static func hex(_ hex: String) -> Color {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xff) / 255
        let g = Double((value >> 8) & 0xff) / 255
        let b = Double(value & 0xff) / 255
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    private static let paperPair = (hex("#f7f3ec"), hex("#1a1714"))
    private static let paper2Pair = (hex("#fffdf8"), hex("#221d19"))
    private static let inkPair = (hex("#241f1a"), hex("#f1e9dc"))
    private static let inkSoftPair = (hex("#5c5247"), hex("#bcae9c"))
    private static let inkFaintPair = (hex("#8a7f72"), hex("#8a7d6c"))
    private static let linePair = (hex("#e4dccf"), hex("#332e27"))
    private static let lineStrongPair = (hex("#d6cbb8"), hex("#423b32"))
    private static let accentPair = (hex("#d97757"), hex("#e08a6a"))
    private static let accentDeepPair = (hex("#b3543a"), hex("#eea486"))
    private static let gridPair = (hex("#ece5d8"), hex("#2b2620"))
    private static let heatSteps: [(NSColor, CGFloat)] = [
        (.white, 0.55), (.white, 0.2), (.black, 0.05), (.black, 0.3),
    ]
    private static let heatStepsDark: [(NSColor, CGFloat)] = [
        (.black, 0.45), (.black, 0.2), (.white, 0.05), (.white, 0.35),
    ]

    public static func paper(_ d: Bool) -> Color { d ? paperPair.1 : paperPair.0 }
    public static func paper2(_ d: Bool) -> Color { d ? paper2Pair.1 : paper2Pair.0 }
    public static func ink(_ d: Bool) -> Color { d ? inkPair.1 : inkPair.0 }
    public static func inkSoft(_ d: Bool) -> Color { d ? inkSoftPair.1 : inkSoftPair.0 }
    public static func inkFaint(_ d: Bool) -> Color { d ? inkFaintPair.1 : inkFaintPair.0 }
    public static func line(_ d: Bool) -> Color { d ? linePair.1 : linePair.0 }
    public static func lineStrong(_ d: Bool) -> Color { d ? lineStrongPair.1 : lineStrongPair.0 }
    public static func accent(_ d: Bool) -> Color {
        guard themeName != "accent" else { return d ? accentPair.1 : accentPair.0 }
        return shifted(themeColor(themeName), toward: d ? .white : .black, by: d ? 0.12 : 0)
    }
    public static func accentDeep(_ d: Bool) -> Color {
        guard themeName != "accent" else { return d ? accentDeepPair.1 : accentDeepPair.0 }
        return shifted(themeColor(themeName), toward: d ? .white : .black, by: d ? 0.3 : 0.25)
    }
    public static func grid(_ d: Bool) -> Color { d ? gridPair.1 : gridPair.0 }
    public static func heat(_ level: Int, _ d: Bool) -> Color {
        let (target, fraction) = (d ? heatStepsDark : heatSteps)[max(0, min(level, 3))]
        return shifted(accent(d), toward: target, by: fraction)
    }
    public static let gold = hex("#c89b3c")
    public static let sage = hex("#6a8d73")
    public static let ok = hex("#34C759")
    public static let warn = hex("#FF9500")
    public static let danger = hex("#FF3B30")

    public static func serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("Iowan Old Style", size: UIScale.pt(size)).weight(weight)
    }
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: UIScale.pt(size), weight: weight, design: .monospaced)
    }

    public static func serifDisplay(_ d: Bool) -> Font { serif(44, weight: .semibold) }
    public static func serifHeading(_ d: Bool) -> Font { serif(20, weight: .semibold) }
    public static func serifLabel(_ d: Bool) -> Font { serif(13.5, weight: .medium) }
}

extension View {
    public func dashFormSkin(_ dark: Bool) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(DashSkin.paper(dark))
            .tint(DashSkin.accent(dark))
            .foregroundStyle(DashSkin.ink(dark))
    }
}

private struct CompactLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var compactLayout: Bool {
        get { self[CompactLayoutKey.self] }
        set { self[CompactLayoutKey.self] = newValue }
    }
}

public struct SkinCard<Content: View>: View {
    let title: String
    var note: String?
    let dark: Bool
    var fill: Bool
    var featured: Bool
    @ViewBuilder var content: () -> Content

    public init(
        title: String, note: String? = nil, dark: Bool, fill: Bool = false, featured: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.note = note
        self.dark = dark
        self.fill = fill
        self.featured = featured
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(DashSkin.serif(18))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer()
                if let note {
                    Text(note)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .multilineTextAlignment(.trailing)
                }
            }
            content()
        }
        .padding(
            EdgeInsets(
                top: UIScale.pt(16), leading: UIScale.pt(16),
                bottom: UIScale.pt(14), trailing: UIScale.pt(16))
        )
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: UIScale.pt(16))
                .fill(DashSkin.paper2(dark))
                .shadow(color: .black.opacity(dark ? 0.32 : 0.05), radius: UIScale.pt(12), y: 8)
        }
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(16)).strokeBorder(
                featured
                    ? AnyShapeStyle(.brassBorder(dark: dark)) : AnyShapeStyle(DashSkin.line(dark)),
                lineWidth: UIScale.pt(featured ? 1.5 : 1))
        )
    }
}

public struct SkinPanel<Content: View>: View {
    let eyebrowLabel: String?
    let dark: Bool
    var fill: Bool
    @ViewBuilder var content: () -> Content

    public init(
        eyebrowLabel: String? = nil, dark: Bool, fill: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.eyebrowLabel = eyebrowLabel
        self.dark = dark
        self.fill = fill
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            if let eyebrowLabel {
                eyebrow(eyebrowLabel)
            }
            content()
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(14))
                .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1))
        )
    }
}
