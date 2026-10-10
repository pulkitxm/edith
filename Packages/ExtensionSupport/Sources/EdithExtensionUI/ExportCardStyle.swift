import AppKit
import EdithExtensionSupport
import SwiftUI

enum ExportCardStyle {
    private static var currentTheme: AppTheme {
        AppTheme(
            storedName: SharedDefaults.store.string(forKey: AppStorageKeys.General.theme)
                ?? AppTheme.accent.rawValue)
    }

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

    private static let paperPair = (exportColor("#f5f5f7"), exportColor("#18181a"))
    private static let paper2Pair = (exportColor("#ffffff"), exportColor("#242426"))
    private static let inkPair = (exportColor("#1d1d1f"), exportColor("#f5f5f7"))
    private static let inkSoftPair = (exportColor("#636366"), exportColor("#b0b0b5"))
    private static let inkFaintPair = (exportColor("#76767b"), exportColor("#98989f"))
    private static let linePair = (exportColor("#e5e5ea"), exportColor("#363639"))
    private static let lineStrongPair = (exportColor("#d2d2d7"), exportColor("#48484a"))
    private static let accentPair = (exportColor("#d97757"), exportColor("#e08a6a"))
    private static let accentDeepPair = (exportColor("#b3543a"), exportColor("#eea486"))
    private static let gridPair = (exportColor("#ebebef"), exportColor("#303033"))
    static func paper(_ d: Bool) -> Color {
        d ? paperPair.1 : paperPair.0
    }
    static func paper(_ d: Bool, theme: AppTheme) -> Color {
        themed(
            paperPair, dark: d, theme: theme, lightFraction: 0.055, darkFraction: 0.1)
    }
    static func paper2(_ d: Bool) -> Color {
        d ? paper2Pair.1 : paper2Pair.0
    }
    static func paper2(_ d: Bool, theme: AppTheme) -> Color {
        themed(
            paper2Pair, dark: d, theme: theme, lightFraction: 0.035, darkFraction: 0.075)
    }
    static func ink(_ d: Bool) -> Color {
        d ? inkPair.1 : inkPair.0
    }
    static func ink(_ d: Bool, theme: AppTheme) -> Color {
        themed(inkPair, dark: d, theme: theme, lightFraction: 0.04, darkFraction: 0.025)
    }
    static func inkSoft(_ d: Bool) -> Color {
        d ? inkSoftPair.1 : inkSoftPair.0
    }
    static func inkSoft(_ d: Bool, theme: AppTheme) -> Color {
        themed(
            inkSoftPair, dark: d, theme: theme, lightFraction: 0.035, darkFraction: 0.02)
    }
    static func inkFaint(_ d: Bool) -> Color {
        d ? inkFaintPair.1 : inkFaintPair.0
    }
    static func inkFaint(_ d: Bool, theme: AppTheme) -> Color {
        themed(
            inkFaintPair, dark: d, theme: theme, lightFraction: 0.03, darkFraction: 0.015)
    }
    static func line(_ d: Bool) -> Color {
        d ? linePair.1 : linePair.0
    }
    static func line(_ d: Bool, theme: AppTheme) -> Color {
        themed(linePair, dark: d, theme: theme, lightFraction: 0.035, darkFraction: 0.06)
    }
    static func lineStrong(_ d: Bool) -> Color {
        d ? lineStrongPair.1 : lineStrongPair.0
    }
    static func lineStrong(_ d: Bool, theme: AppTheme) -> Color {
        themed(
            lineStrongPair, dark: d, theme: theme, lightFraction: 0.045,
            darkFraction: 0.08)
    }
    static func accent(_ d: Bool) -> Color {
        accent(d, theme: currentTheme)
    }
    static func accent(_ d: Bool, theme: AppTheme) -> Color {
        guard theme != .accent else { return d ? accentPair.1 : accentPair.0 }
        return shifted(theme.color, toward: d ? .white : .black, by: d ? 0.12 : 0)
    }
    static func accentDeep(_ d: Bool) -> Color {
        guard currentTheme != .accent else { return d ? accentDeepPair.1 : accentDeepPair.0 }
        return shifted(currentTheme.color, toward: d ? .white : .black, by: d ? 0.3 : 0.25)
    }
    static func grid(_ d: Bool) -> Color {
        d ? gridPair.1 : gridPair.0
    }
    static func grid(_ d: Bool, theme: AppTheme) -> Color {
        themed(gridPair, dark: d, theme: theme, lightFraction: 0.03, darkFraction: 0.06)
    }
    static let gold = exportColor("#c89b3c")
    static let sage = exportColor("#6a8d73")
    static let networkDownload = exportColor("#5685a3")
    static let networkUpload = exportColor("#b27691")
    static let ok = exportColor("#34C759")
    static let warn = exportColor("#FF9500")
    static let danger = exportColor("#FF3B30")

    static func heading(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: UIScale.pt(size), weight: weight)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: UIScale.pt(size), weight: weight, design: .monospaced)
    }
}

private func exportColor(_ hex: String) -> Color {
    let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return Color(
        red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
        blue: Double(value & 255) / 255)
}
