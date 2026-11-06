import EdithExtensionCore
import AppKit
import SwiftUI

public enum EdithButtonRole: Sendable, CaseIterable, Hashable {
    case primary
    case secondary
    case borderless
    case toolbar
    case destructive
    case row
    case iconOnly
    case selection

    var usesFeatureAppearance: Bool {
        switch self {
        case .borderless:
            true
        case .primary, .secondary, .destructive, .row, .selection, .toolbar, .iconOnly:
            false
        }
    }
}

struct EdithButtonMetrics: Equatable, Sendable {
    let horizontalPadding: Double
    let verticalPadding: Double
    let minimumWidth: Double
    let minimumHeight: Double
    let cornerRadius: Double

    static func metrics(for role: EdithButtonRole) -> Self {
        switch role {
        case .primary, .secondary, .destructive:
            Self(
                horizontalPadding: 12, verticalPadding: 6, minimumWidth: 32,
                minimumHeight: 32, cornerRadius: 7)
        case .borderless:
            Self(
                horizontalPadding: 0, verticalPadding: 0, minimumWidth: 0,
                minimumHeight: 0, cornerRadius: 6)
        case .toolbar, .iconOnly:
            Self(
                horizontalPadding: 6, verticalPadding: 4, minimumWidth: 28,
                minimumHeight: 28, cornerRadius: 6)
        case .row, .selection:
            Self(
                horizontalPadding: 9, verticalPadding: 7, minimumWidth: 32,
                minimumHeight: 32, cornerRadius: 8)
        }
    }

    func visibleSize(label: CGSize) -> CGSize {
        CGSize(
            width: max(minimumWidth, label.width + horizontalPadding * 2),
            height: max(minimumHeight, label.height + verticalPadding * 2))
    }

    func contains(_ point: CGPoint, label: CGSize) -> Bool {
        let size = visibleSize(label: label)
        return point.x >= 0 && point.y >= 0 && point.x <= size.width && point.y <= size.height
    }
}

public struct EdithButtonStyle: ButtonStyle {
    public let role: EdithButtonRole
    public let selected: Bool
    public let tint: Color?

    public init(
        _ role: EdithButtonRole, selected: Bool = false, tint: Color? = nil
    ) {
        self.role = role
        self.selected = selected
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        EdithButtonBody(
            label: configuration.label, role: role, selected: selected,
            pressed: configuration.isPressed, tint: tint)
    }
}

public struct EdithButtonTarget: ViewModifier {
    public let role: EdithButtonRole

    public init(_ role: EdithButtonRole) {
        self.role = role
    }

    public func body(content: Content) -> some View {
        let metrics = EdithButtonMetrics.metrics(for: role)
        let fillsWidth = role == .row || role == .selection
        if role.usesFeatureAppearance {
            content.contentShape(Rectangle())
        } else {
            content
                .frame(
                    minWidth: UIScale.pt(metrics.minimumWidth),
                    maxWidth: fillsWidth ? .infinity : nil,
                    minHeight: UIScale.pt(metrics.minimumHeight),
                    alignment: fillsWidth ? .leading : .center
                )
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == EdithButtonStyle {
    public static func edith(
        _ role: EdithButtonRole, selected: Bool = false, tint: Color? = nil
    ) -> EdithButtonStyle {
        EdithButtonStyle(role, selected: selected, tint: tint)
    }
}

private struct EdithButtonBody<Label: View>: View {
    let label: Label
    let role: EdithButtonRole
    let selected: Bool
    let pressed: Bool
    let tint: Color?

    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.process.defaults())
    private var themeName = "accent"

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.font) private var font
    @Environment(\.edithInteractionPreview) private var preview
    @State private var hovering = false

    private var metrics: EdithButtonMetrics { .metrics(for: role) }
    private var cornerRadius: CGFloat { UIScale.pt(metrics.cornerRadius) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
    private var fillsWidth: Bool { role == .row || role == .selection }
    private var inactive: Bool { activeState == .inactive }
    private var interaction: EdithInteractionState {
        EdithInteractionState.resolve(
            hovering: hovering, pressed: pressed, enabled: enabled, preview: preview)
    }
    private var plateTone: EdithHoverTone { palette.plateTone }
    private var showsPlate: Bool {
        guard fillsWidth, selected else { return interaction.active }
        return interaction.pressed
    }

    @ViewBuilder var body: some View {
        if role.usesFeatureAppearance {
            label
                .font(font ?? .edithText(.body))
                .overlay {
                    EdithOutsetHoverPlate(
                        state: interaction, focused: focused && enabled, tint: tint,
                        tone: plateTone, cornerRadius: nil, outset: true)
                }
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : EdithInteractionMetrics.disabledOpacity)
                .onHover { hovering = $0 }
                .animation(
                    Motion.animation(Motion.feedback, reduceMotion: reduceMotion),
                    value: interaction
                )
                .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
        } else {
            label
                .font(font ?? .edithText(.body))
                .padding(.horizontal, UIScale.pt(metrics.horizontalPadding))
                .padding(.vertical, UIScale.pt(metrics.verticalPadding))
                .frame(
                    minWidth: UIScale.pt(metrics.minimumWidth),
                    maxWidth: fillsWidth ? .infinity : nil,
                    minHeight: UIScale.pt(metrics.minimumHeight),
                    alignment: fillsWidth ? .leading : .center
                )
                .foregroundStyle(foreground)
                .background {
                    ZStack {
                        shape.fill(background)
                        EdithHoverPlate(
                            hovered: showsPlate, pressed: interaction.pressed && showsPlate,
                            tint: tint, tone: plateTone, cornerRadius: cornerRadius)
                    }
                }
                .overlay(shape.strokeBorder(border, lineWidth: borderWidth))
                .contentShape(Rectangle())
                .opacity(
                    enabled ? (inactive ? 0.72 : 1) : EdithInteractionMetrics.disabledOpacity
                )
                .onHover { hovering = $0 }
                .animation(
                    Motion.animation(Motion.feedback, reduceMotion: reduceMotion),
                    value: interaction
                )
                .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
        }
    }

    private var palette: EdithButtonPalette {
        EdithButtonPalette(
            role: role, selected: selected, tint: tint, themeName: themeName,
            dark: scheme == .dark, increasedContrast: contrast == .increased,
            differentiateWithoutColor: differentiateWithoutColor)
    }

    private var foreground: Color { palette.foreground }
    private var background: Color { palette.background }
    private var border: Color { palette.border(focused: focused && enabled) }
    private var borderWidth: Double { palette.borderWidth(focused: focused && enabled) }
}

struct EdithButtonPalette {
    let role: EdithButtonRole
    let selected: Bool
    let tint: Color?
    let themeName: String
    let dark: Bool
    let increasedContrast: Bool
    let differentiateWithoutColor: Bool

    var resolvedTint: Color { tint ?? themeColor(themeName) }

    var plateTone: EdithHoverTone {
        switch role {
        case .row, .selection, .primary, .destructive: .neutral
        case .secondary, .toolbar, .iconOnly, .borderless: .tinted
        }
    }

    var foreground: Color {
        switch role {
        case .primary:
            return tint.map { OnAccent.foreground(on: $0, dark: dark) }
                ?? themeOnAccentColor(themeName)
        case .destructive:
            return .white
        case .toolbar, .iconOnly:
            return tint ?? .primary
        default:
            return .primary
        }
    }

    var background: Color {
        guard !role.usesFeatureAppearance else { return .clear }
        let boost = increasedContrast ? 0.05 : 0
        switch role {
        case .primary:
            return resolvedTint.opacity(0.9)
        case .destructive:
            return Color.red.opacity(0.88)
        case .secondary:
            return Color.primary.opacity((selected ? 0.11 : 0.07) + boost)
        case .row, .selection:
            if selected { return resolvedTint.opacity(0.2 + boost) }
            return Color.primary.opacity(boost)
        case .toolbar, .iconOnly:
            return Color.primary.opacity(selected ? 0.08 + boost : boost)
        case .borderless:
            return .clear
        }
    }

    func border(focused: Bool) -> Color {
        guard !role.usesFeatureAppearance else { return .clear }
        if focused { return resolvedTint.opacity(0.95) }
        if selected, differentiateWithoutColor { return Color.primary.opacity(0.75) }
        switch role {
        case .secondary:
            return Color.primary.opacity(increasedContrast ? 0.34 : 0.18)
        case .primary, .destructive:
            return Color.white.opacity(increasedContrast ? 0.7 : 0.2)
        case .row, .selection, .borderless, .toolbar, .iconOnly:
            return .clear
        }
    }

    func borderWidth(focused: Bool) -> Double {
        if focused || (selected && differentiateWithoutColor) { return 2 }
        return increasedContrast ? 1 : 0.75
    }
}

extension View {
    public func edithButtonTarget(_ role: EdithButtonRole) -> some View {
        modifier(EdithButtonTarget(role))
    }

    @ViewBuilder
    public func presenterBlur(_ on: Bool, radius: CGFloat = 4) -> some View {
        if on {
            blur(radius: UIScale.pt(radius))
        } else {
            self
        }
    }

    public func presenterTextBlur(_ on: Bool, fontSize: CGFloat) -> some View {
        presenterBlur(on, radius: max(4, fontSize * 0.4))
            .privacySensitive(on)
    }

    @ViewBuilder
    public func presenterCover(_ on: Bool, dark: Bool = true) -> some View {
        if on {
            compositingGroup()
                .blur(radius: UIScale.pt(PresenterLayerCover.blurRadius))
                .overlay {
                    (dark ? Color.black : Color.white).opacity(
                        Double(PresenterLayerCover.dimOpacity)
                    )
                    .allowsHitTesting(false)
                }
                .privacySensitive(true)
        } else {
            self
        }
    }

    public func settingsCaption() -> some View {
        font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
    }

    public func settingsSubtitle() -> some View {
        font(.edithText(.body)).foregroundStyle(.secondary)
    }

    public func card() -> some View {
        padding(UIScale.pt(16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .edithSurface()
    }

    public func widgetBar<F: ShapeStyle>(
        cornerRadius: CGFloat,
        fill: F,
        stroke: Color? = nil,
        strokeWidth: CGFloat = 1,
        shadow: Color? = nil,
        shadowRadius: CGFloat = 12,
        shadowY: CGFloat = 8,
        clipsContent: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: UIScale.pt(cornerRadius))
        return
            self
            .background(fill, in: shape)
            .clipped(clipsContent, to: shape)
            .background {
                if let shadow {
                    shape.fill(fill)
                        .shadow(
                            color: shadow, radius: UIScale.pt(shadowRadius), y: UIScale.pt(shadowY))
                }
            }
            .overlay {
                if let stroke {
                    shape.strokeBorder(stroke, lineWidth: UIScale.pt(strokeWidth))
                }
            }
    }

    @ViewBuilder
    private func clipped<S: Shape>(_ clip: Bool, to shape: S) -> some View {
        if clip {
            clipShape(shape)
        } else {
            self
        }
    }

    @available(macOS 26.0, *)
    private func edithGlassStyle(_ tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    @ViewBuilder
    public func edithGlass<S: Shape>(_ tint: Color? = nil, interactive: Bool = false, in shape: S)
        -> some View
    {
        if #available(macOS 26.0, *) {
            self.glassEffect(edithGlassStyle(tint, interactive: interactive), in: shape)
        } else if let tint {
            self.background(tint.opacity(0.18), in: shape)
        } else {
            self.background(.thinMaterial, in: shape)
        }
    }
}

extension Color {
    public var hex6: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

public func eyebrow(_ text: String) -> some View {
    PageCapsLabel(text)
}

public struct EmptyStateText: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.edithText(.callout))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, UIScale.pt(24))
            .padding(.horizontal, UIScale.pt(16))
            .frame(maxWidth: .infinity)
    }
}

public struct TerminalLogView: View {
    let log: String
    let theme: Color
    var height: CGFloat = 140

    public init(log: String, theme: Color, height: CGFloat = 140) {
        self.log = log
        self.theme = theme
        self.height = height
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(log.isEmpty ? "No output yet - hit reload" : log)
                    .font(.system(size: UIScale.pt(11), design: .monospaced))
                    .foregroundStyle(theme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("end")
            }
            .onChange(of: log) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(height: height)
        .padding(UIScale.pt(8))
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
    }
}
