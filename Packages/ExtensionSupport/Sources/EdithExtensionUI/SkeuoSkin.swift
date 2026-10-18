import EdithExtensionSupport
import AppKit
import SwiftUI

public enum SkeuoDepth: Sendable, Hashable {
    case flat
    case recessed
    case raised
    case pressed
}

public enum SkeuoSkin {
    private static func shifted(_ color: Color, toward target: NSColor, by fraction: CGFloat)
        -> Color
    {
        let base = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return Color(base.blended(withFraction: fraction, of: target) ?? base)
    }

    public static func surfaceTop(_ d: Bool, theme: AppTheme) -> Color {
        DashSkin.paper2(d, theme: theme)
    }

    public static func surfaceBottom(_ d: Bool, theme: AppTheme) -> Color {
        DashSkin.paper(d, theme: theme)
    }

    public static func keyTop(_ d: Bool, theme: AppTheme) -> Color {
        d ? DashSkin.line(d, theme: theme) : DashSkin.paper2(d, theme: theme)
    }

    public static func keyBottom(_ d: Bool, theme: AppTheme) -> Color {
        d ? DashSkin.paper2(d, theme: theme) : DashSkin.grid(d, theme: theme)
    }

    public static func keyEdge(_ d: Bool, theme: AppTheme, increased: Bool) -> Color {
        d
            ? Color.black.opacity(increased ? 0.85 : 0.6)
            : DashSkin.lineStrong(d, theme: theme).opacity(increased ? 1 : 0.9)
    }

    public static func highlight(_ d: Bool) -> Color {
        Color.white.opacity(d ? 0.09 : 0.9)
    }

    public static func shade(_ d: Bool) -> Color {
        Color.black.opacity(d ? 0.55 : 0.14)
    }

    public static func well(_ d: Bool, deep: Bool) -> Color {
        Color.black.opacity(d ? (deep ? 0.32 : 0.2) : (deep ? 0.085 : 0.045))
    }

    public static func tintTop(_ tint: Color) -> Color {
        shifted(tint, toward: .white, by: 0.18)
    }

    public static func tintBottom(_ tint: Color) -> Color {
        shifted(tint, toward: .black, by: 0.14)
    }

    public static func plateTop(_ d: Bool) -> Color {
        d ? shifted(DashSkin.paper2(d), toward: .white, by: 0.035) : DashSkin.paper2(d)
    }

    public static func plateBottom(_ d: Bool) -> Color {
        d ? DashSkin.paper2(d) : shifted(DashSkin.paper2(d), toward: .black, by: 0.025)
    }

    public static func pageBottom(_ d: Bool) -> Color {
        shifted(DashSkin.paper(d), toward: .black, by: d ? 0.12 : 0.035)
    }

    public static func embossing(onTint: Bool, dark: Bool) -> (color: Color, y: CGFloat) {
        onTint ? (Color.black.opacity(0.28), -1) : engraving(dark)
    }

    public static func engraving(_ d: Bool) -> (color: Color, y: CGFloat) {
        d ? (Color.black.opacity(0.65), -1) : (Color.white.opacity(0.85), 1)
    }
}

public struct SkeuoSurface: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = "accent"

    public init() {}

    public var body: some View {
        let dark = scheme == .dark
        let theme = AppTheme(storedName: themeName)
        LinearGradient(
            colors: [
                SkeuoSkin.surfaceTop(dark, theme: theme),
                SkeuoSkin.surfaceBottom(dark, theme: theme),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(alignment: .top) {
            SkeuoSkin.highlight(dark).frame(height: UIScale.pt(1))
        }
    }
}

public struct SkeuoGroove: View {
    public enum Axis: Sendable {
        case horizontal
        case vertical
    }

    public let axis: Axis
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    public var body: some View {
        let dark = scheme == .dark
        let line = UIScale.pt(1)
        let shade = SkeuoSkin.shade(dark).opacity(contrast == .increased ? 1 : 0.85)
        let lit = SkeuoSkin.highlight(dark)
        switch axis {
        case .horizontal:
            VStack(spacing: 0) {
                shade.frame(height: line)
                lit.frame(height: line)
            }
            .frame(maxWidth: .infinity)
        case .vertical:
            HStack(spacing: 0) {
                shade.frame(width: line)
                lit.frame(width: line)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

public struct SkeuoKey: View {
    public let depth: SkeuoDepth
    public let cornerRadius: CGFloat
    public let tint: Color?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = "accent"

    public init(_ depth: SkeuoDepth, cornerRadius: CGFloat = 8, tint: Color? = nil) {
        self.depth = depth
        self.cornerRadius = cornerRadius
        self.tint = tint
    }

    public var body: some View {
        let dark = scheme == .dark
        let theme = AppTheme(storedName: themeName)
        let increased = contrast == .increased
        let shape = RoundedRectangle(cornerRadius: UIScale.pt(cornerRadius), style: .continuous)
        switch depth {
        case .flat:
            if let tint {
                shape.fill(tint.opacity(0.16))
            } else {
                Color.clear
            }
        case .raised:
            shape
                .fill(
                    LinearGradient(
                        colors: tint.map { [SkeuoSkin.tintTop($0), SkeuoSkin.tintBottom($0)] }
                            ?? [
                                SkeuoSkin.keyTop(dark, theme: theme),
                                SkeuoSkin.keyBottom(dark, theme: theme),
                            ],
                        startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                tint == nil ? SkeuoSkin.highlight(dark) : .white.opacity(0.35),
                                .clear,
                            ],
                            startPoint: .top, endPoint: .center),
                        lineWidth: UIScale.pt(1))
                )
                .overlay(
                    shape.strokeBorder(
                        SkeuoSkin.keyEdge(dark, theme: theme, increased: increased),
                        lineWidth: UIScale.pt(increased ? 1 : 0.5))
                )
                .shadow(
                    color: Color.black.opacity(dark ? 0.45 : 0.1), radius: UIScale.pt(1),
                    y: UIScale.pt(1)
                )
                .shadow(
                    color: Color.black.opacity(dark ? 0.25 : 0.06), radius: UIScale.pt(4),
                    y: UIScale.pt(2))
        case .recessed, .pressed:
            let deep = depth == .pressed
            shape
                .fill(
                    (tint.map { $0.opacity(deep ? 0.95 : 0.85) }
                        ?? SkeuoSkin.well(dark, deep: deep))
                        .shadow(
                            .inner(
                                color: SkeuoSkin.shade(dark).opacity(deep ? 1 : 0.8),
                                radius: UIScale.pt(deep ? 2.5 : 1.5),
                                y: UIScale.pt(deep ? 1.5 : 1)))
                )
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.clear, SkeuoSkin.highlight(dark)],
                            startPoint: .center, endPoint: .bottom),
                        lineWidth: UIScale.pt(1))
                )
                .overlay {
                    if increased {
                        shape.strokeBorder(
                            SkeuoSkin.keyEdge(dark, theme: theme, increased: true),
                            lineWidth: UIScale.pt(1))
                    }
                }
        }
    }
}

public struct SkeuoLED: View {
    public let tint: Color
    @Environment(\.colorScheme) private var scheme

    public init(tint: Color) {
        self.tint = tint
    }

    public var body: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [SkeuoSkin.tintTop(tint), tint],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.black.opacity(0.25), lineWidth: UIScale.pt(0.5))
            )
            .frame(width: UIScale.pt(3), height: UIScale.pt(14))
            .shadow(color: tint.opacity(scheme == .dark ? 0.85 : 0.55), radius: UIScale.pt(3))
            .accessibilityHidden(true)
    }
}

public struct SkeuoRowStyle: ButtonStyle {
    public let selected: Bool
    public let tint: Color?

    public init(selected: Bool = false, tint: Color? = nil) {
        self.selected = selected
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        SkeuoRowBody(
            label: configuration.label, selected: selected,
            pressed: configuration.isPressed, tint: tint)
    }
}

extension ButtonStyle where Self == SkeuoRowStyle {
    public static func skeuoRow(selected: Bool = false, tint: Color? = nil) -> SkeuoRowStyle {
        SkeuoRowStyle(selected: selected, tint: tint)
    }
}

private struct SkeuoRowBody<Label: View>: View {
    let label: Label
    let selected: Bool
    let pressed: Bool
    let tint: Color?

    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = "accent"

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    private var metrics: EdithButtonMetrics { .metrics(for: .row) }
    private var resolvedTint: Color { tint ?? themeColor(themeName) }

    private var depth: SkeuoDepth {
        guard enabled else { return selected ? .raised : .flat }
        if pressed { return .pressed }
        if selected { return .raised }
        return hovering ? .recessed : .flat
    }

    var body: some View {
        let engraving = SkeuoSkin.engraving(scheme == .dark)
        let shape = RoundedRectangle(
            cornerRadius: UIScale.pt(metrics.cornerRadius), style: .continuous)
        label
            .shadow(color: engraving.color, radius: 0, y: UIScale.pt(engraving.y))
            .padding(.horizontal, UIScale.pt(metrics.horizontalPadding))
            .padding(.vertical, UIScale.pt(metrics.verticalPadding))
            .frame(
                minWidth: UIScale.pt(metrics.minimumWidth),
                maxWidth: .infinity,
                minHeight: UIScale.pt(metrics.minimumHeight),
                alignment: .leading
            )
            .foregroundStyle(.primary)
            .background { SkeuoKey(depth, cornerRadius: metrics.cornerRadius) }
            .overlay(alignment: .leading) {
                if selected {
                    SkeuoLED(tint: resolvedTint)
                        .padding(.leading, UIScale.pt(3))
                        .transition(.opacity)
                }
            }
            .overlay {
                if focused, enabled {
                    shape.strokeBorder(resolvedTint.opacity(0.95), lineWidth: 2)
                } else if selected, differentiateWithoutColor {
                    shape.strokeBorder(Color.primary.opacity(0.75), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .opacity(enabled ? (activeState == .inactive ? 0.78 : 1) : 0.42)
            .onHover { hovering = enabled && $0 }
            .animation(
                Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: hovering
            )
            .animation(
                Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: pressed
            )
            .animation(
                Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: selected
            )
            .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }
}

extension View {
    public func skeuoEngraved(_ dark: Bool) -> some View {
        let engraving = SkeuoSkin.engraving(dark)
        return shadow(color: engraving.color, radius: 0, y: UIScale.pt(engraving.y))
    }
}

public struct SkeuoPlate: ViewModifier {
    public let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = "accent"

    public init(cornerRadius: CGFloat = 12) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        let dark = scheme == .dark
        let increased = contrast == .increased
        let shape = RoundedRectangle(cornerRadius: UIScale.pt(cornerRadius), style: .continuous)
        content
            .background {
                shape
                    .fill(
                        LinearGradient(
                            colors: [SkeuoSkin.plateTop(dark), SkeuoSkin.plateBottom(dark)],
                            startPoint: .top, endPoint: .bottom)
                    )
                    .shadow(
                        color: Color.black.opacity(dark ? 0.4 : 0.07), radius: UIScale.pt(1),
                        y: UIScale.pt(1)
                    )
                    .shadow(
                        color: Color.black.opacity(dark ? 0.28 : 0.05), radius: UIScale.pt(10),
                        y: UIScale.pt(4))
            }
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [SkeuoSkin.highlight(dark), .clear],
                            startPoint: .top, endPoint: .center),
                        lineWidth: UIScale.pt(1)
                    )
                    .overlay(
                        shape.strokeBorder(
                            SkeuoSkin.keyEdge(
                                dark, theme: AppTheme(storedName: themeName), increased: increased),
                            lineWidth: UIScale.pt(increased ? 1 : 0.5))
                    )
                    .allowsHitTesting(false)
            }
    }
}

public struct SkeuoPageBackground: View {
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        let dark = scheme == .dark
        LinearGradient(
            colors: [DashSkin.paper(dark), SkeuoSkin.pageBottom(dark)],
            startPoint: .top, endPoint: .bottom)
    }
}

public struct SkeuoSwitchStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SkeuoSwitch(configuration: configuration)
    }
}

extension ToggleStyle where Self == SkeuoSwitchStyle {
    public static var skeuoSwitch: SkeuoSwitchStyle { SkeuoSwitchStyle() }
}

private struct SkeuoSwitch: View {
    let configuration: ToggleStyleConfiguration

    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = "accent"
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var height: CGFloat {
        switch controlSize {
        case .mini: 14
        case .small: 18
        default: 22
        }
    }

    var body: some View {
        let on = configuration.isOn
        let tint = themeColor(themeName)
        let track = Capsule(style: .continuous)
        let width = height * 1.75
        let knob = height - 4
        HStack(spacing: UIScale.pt(8)) {
            configuration.label
            Button {
                configuration.isOn.toggle()
            } label: {
                ZStack(alignment: on ? .trailing : .leading) {
                    SkeuoKey(.recessed, cornerRadius: height / 2, tint: on ? tint : nil)
                    Circle()
                        .fill(Color.clear)
                        .background { SkeuoKey(.raised, cornerRadius: knob / 2) }
                        .frame(width: UIScale.pt(knob), height: UIScale.pt(knob))
                        .padding(UIScale.pt(2))
                }
                .frame(width: UIScale.pt(width), height: UIScale.pt(height))
                .overlay {
                    if focused, enabled {
                        track.strokeBorder(tint.opacity(0.9), lineWidth: 2)
                    }
                }
                .contentShape(track)
            }
            .buttonStyle(.plain)
            .animation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: on)
        }
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

public struct SkeuoFieldStyle: TextFieldStyle {
    public init() {}

    public func _body(configuration: TextField<Self._Label>) -> some View {
        SkeuoField { configuration }
    }
}

extension TextFieldStyle where Self == SkeuoFieldStyle {
    public static var skeuoField: SkeuoFieldStyle { SkeuoFieldStyle() }
}

private struct SkeuoField<Field: View>: View {
    @ViewBuilder let field: () -> Field
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = "accent"
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: UIScale.pt(6), style: .continuous)
        field()
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, UIScale.pt(7))
            .padding(.vertical, UIScale.pt(4))
            .background { SkeuoKey(.recessed, cornerRadius: 6) }
            .overlay {
                if focused {
                    shape.strokeBorder(themeColor(themeName).opacity(0.85), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .opacity(enabled ? 1 : 0.5)
    }
}
