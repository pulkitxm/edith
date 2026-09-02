import AppKit
import EdithKit
import SwiftUI

enum DashSkin {
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

    private static let paperPair = (DashPalette.color("#f7f3ec"), DashPalette.color("#1a1714"))
    private static let paper2Pair = (DashPalette.color("#fffdf8"), DashPalette.color("#221d19"))
    private static let inkPair = (DashPalette.color("#241f1a"), DashPalette.color("#f1e9dc"))
    private static let inkSoftPair = (DashPalette.color("#5c5247"), DashPalette.color("#bcae9c"))
    private static let inkFaintPair = (DashPalette.color("#8a7f72"), DashPalette.color("#8a7d6c"))
    private static let linePair = (DashPalette.color("#e4dccf"), DashPalette.color("#332e27"))
    private static let lineStrongPair = (DashPalette.color("#d6cbb8"), DashPalette.color("#423b32"))
    private static let accentPair = (DashPalette.color("#d97757"), DashPalette.color("#e08a6a"))
    private static let accentDeepPair = (DashPalette.color("#b3543a"), DashPalette.color("#eea486"))
    private static let gridPair = (DashPalette.color("#ece5d8"), DashPalette.color("#2b2620"))
    private static let heatSteps: [(NSColor, CGFloat)] = [
        (.white, 0.55), (.white, 0.2), (.black, 0.05), (.black, 0.3),
    ]
    private static let heatStepsDark: [(NSColor, CGFloat)] = [
        (.black, 0.45), (.black, 0.2), (.white, 0.05), (.white, 0.35),
    ]

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
    static func heat(_ level: Int, _ d: Bool) -> Color {
        let (target, fraction) = (d ? heatStepsDark : heatSteps)[max(0, min(level, 3))]
        return shifted(accent(d), toward: target, by: fraction)
    }
    static let gold = DashPalette.color("#c89b3c")
    static let sage = DashPalette.color("#6a8d73")
    static let networkDownload = DashPalette.color("#5685a3")
    static let networkUpload = DashPalette.color("#b27691")
    static let ok = DashPalette.color("#34C759")
    static let warn = DashPalette.color("#FF9500")
    static let danger = DashPalette.color("#FF3B30")

    static func serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("Iowan Old Style", size: UIScale.pt(size)).weight(weight)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: UIScale.pt(size), weight: weight, design: .monospaced)
    }
}

private struct CompactLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var compactLayout: Bool {
        get { self[CompactLayoutKey.self] }
        set { self[CompactLayoutKey.self] = newValue }
    }
}

struct SkinCard<Content: View>: View {
    let title: String
    var note: String? = nil
    let dark: Bool
    var fill = false
    @ViewBuilder var content: () -> Content

    var body: some View {
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
        .widgetBar(
            cornerRadius: 16,
            fill: DashSkin.paper2(dark),
            stroke: DashSkin.line(dark),
            shadow: .black.opacity(dark ? 0.32 : 0.05)
        )
    }
}

struct LazyChartCard<Content: View>: View {
    let title: String
    var note: String? = nil
    let dark: Bool
    var placeholderHeight: CGFloat = UIScale.pt(224)
    @ViewBuilder var content: () -> Content
    @State private var loaded = false

    var body: some View {
        SkinCard(title: title, note: note, dark: dark) {
            Group {
                if loaded {
                    content()
                } else {
                    SkeletonGroup {
                        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                            HStack(alignment: .bottom, spacing: UIScale.pt(6)) {
                                ForEach(0..<12, id: \.self) { index in
                                    SkeletonBlock(
                                        height: CGFloat(32 + index % 5 * 22),
                                        corner: 3)
                                }
                            }
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            HStack {
                                SkeletonBlock(width: 58, height: 8)
                                Spacer()
                                SkeletonBlock(width: 58, height: 8)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: placeholderHeight)
                    .accessibilityLabel("Loading \(title)")
                }
            }
        }
        .task {
            guard !loaded else { return }
            await Task.yield()
            loaded = true
        }
    }
}
