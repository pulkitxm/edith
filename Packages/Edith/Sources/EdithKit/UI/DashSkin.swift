import AppKit
import SwiftUI

public enum DashSkin {
    private static var currentTheme: AppTheme { ThemeStore.current }

    private static func shifted(_ color: Color, toward target: NSColor, by fraction: CGFloat)
        -> Color
    {
        let base = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return Color(base.blended(withFraction: fraction, of: target) ?? base)
    }

    private static func themed(
        _ pair: (Color, Color), dark: Bool, theme: AppTheme, lightFraction: CGFloat,
        darkFraction: CGFloat
    ) -> Color {
        let base = dark ? pair.1 : pair.0
        guard theme != .accent else { return base }
        return shifted(base, toward: NSColor(theme.color), by: dark ? darkFraction : lightFraction)
    }

    private static let paperPair = (ThemeColor.color("#f5f5f7"), ThemeColor.color("#18181a"))
    private static let paper2Pair = (ThemeColor.color("#ffffff"), ThemeColor.color("#242426"))
    private static let inkPair = (ThemeColor.color("#1d1d1f"), ThemeColor.color("#f5f5f7"))
    private static let inkSoftPair = (ThemeColor.color("#636366"), ThemeColor.color("#b0b0b5"))
    private static let inkFaintPair = (ThemeColor.color("#76767b"), ThemeColor.color("#98989f"))
    private static let linePair = (ThemeColor.color("#e5e5ea"), ThemeColor.color("#363639"))
    private static let lineStrongPair = (ThemeColor.color("#d2d2d7"), ThemeColor.color("#48484a"))
    private static let accentDeepPair = (ThemeColor.color("#b3543a"), ThemeColor.color("#eea486"))
    private static let gridPair = (ThemeColor.color("#ebebef"), ThemeColor.color("#303033"))
    private static let heatSteps: [(NSColor, CGFloat)] = [
        (.black, 0.3), (.black, 0.05), (.white, 0.2), (.white, 0.55),
    ]
    private static let heatStepsDark: [(NSColor, CGFloat)] = [
        (.black, 0.45), (.black, 0.2), (.white, 0.05), (.white, 0.35),
    ]

    private static func adaptive(_ pair: (Color, Color)) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                NSColor(appearance.isDark ? pair.1 : pair.0)
            })
    }

    public static let canvas = adaptive(paperPair)
    public static let panel = adaptive(paper2Pair)
    public static let hairline = adaptive(linePair)

    public static func paper(_ d: Bool) -> Color {
        d ? paperPair.1 : paperPair.0
    }
    public static func paper(_ d: Bool, theme: AppTheme) -> Color {
        themed(
            paperPair, dark: d, theme: theme, lightFraction: 0.055, darkFraction: 0.1)
    }
    public static func paper2(_ d: Bool) -> Color {
        d ? paper2Pair.1 : paper2Pair.0
    }
    public static func paper2(_ d: Bool, theme: AppTheme) -> Color {
        themed(
            paper2Pair, dark: d, theme: theme, lightFraction: 0.035, darkFraction: 0.075)
    }
    public static func ink(_ d: Bool) -> Color {
        d ? inkPair.1 : inkPair.0
    }
    public static func ink(_ d: Bool, theme: AppTheme) -> Color {
        themed(inkPair, dark: d, theme: theme, lightFraction: 0.04, darkFraction: 0.025)
    }
    public static func inkSoft(_ d: Bool) -> Color {
        d ? inkSoftPair.1 : inkSoftPair.0
    }
    public static func inkSoft(_ d: Bool, theme: AppTheme) -> Color {
        themed(
            inkSoftPair, dark: d, theme: theme, lightFraction: 0.035, darkFraction: 0.02)
    }
    public static func inkFaint(_ d: Bool) -> Color {
        d ? inkFaintPair.1 : inkFaintPair.0
    }
    public static func inkFaint(_ d: Bool, theme: AppTheme) -> Color {
        themed(
            inkFaintPair, dark: d, theme: theme, lightFraction: 0.03, darkFraction: 0.015)
    }
    public static func line(_ d: Bool) -> Color {
        d ? linePair.1 : linePair.0
    }
    public static func line(_ d: Bool, theme: AppTheme) -> Color {
        themed(linePair, dark: d, theme: theme, lightFraction: 0.035, darkFraction: 0.06)
    }
    public static func lineStrong(_ d: Bool) -> Color {
        d ? lineStrongPair.1 : lineStrongPair.0
    }
    public static func lineStrong(_ d: Bool, theme: AppTheme) -> Color {
        themed(
            lineStrongPair, dark: d, theme: theme, lightFraction: 0.045,
            darkFraction: 0.08)
    }
    public static func accent(_ d: Bool) -> Color {
        accent(d, theme: currentTheme)
    }
    public static func accent(_ d: Bool, theme: AppTheme) -> Color {
        theme.accent(dark: d)
    }
    public static func accentDeep(_ d: Bool) -> Color {
        guard currentTheme != .accent else { return d ? accentDeepPair.1 : accentDeepPair.0 }
        return shifted(currentTheme.color, toward: d ? .white : .black, by: d ? 0.3 : 0.25)
    }
    public static func grid(_ d: Bool) -> Color {
        d ? gridPair.1 : gridPair.0
    }
    public static func grid(_ d: Bool, theme: AppTheme) -> Color {
        themed(gridPair, dark: d, theme: theme, lightFraction: 0.03, darkFraction: 0.06)
    }
    public static func heat(_ level: Int, _ d: Bool) -> Color {
        let (target, fraction) = (d ? heatStepsDark : heatSteps)[max(0, min(level, 3))]
        return shifted(accent(d), toward: target, by: fraction)
    }
    public static let gold = ThemeColor.color("#c89b3c")
    public static let sage = ThemeColor.color("#6a8d73")
    public static let networkDownload = ThemeColor.color("#5685a3")
    public static let networkUpload = ThemeColor.color("#b27691")
    public static let ok = ThemeColor.color("#34C759")
    public static let warn = ThemeColor.color("#FF9500")
    public static let danger = ThemeColor.color("#FF3B30")

    public static func heading(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: UIScale.pt(size), weight: weight)
    }
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: UIScale.pt(size), weight: weight, design: .monospaced)
    }
}
