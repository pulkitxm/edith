import EdithExtensionSupport
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

    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = "accent"

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    private var metrics: EdithButtonMetrics { .metrics(for: role) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: UIScale.pt(metrics.cornerRadius))
    }
    private var fillsWidth: Bool { role == .row || role == .selection }
    private var inactive: Bool { activeState == .inactive }
    private var resolvedTint: Color { tint ?? themeColor(themeName) }

    @ViewBuilder var body: some View {
        if role.usesFeatureAppearance {
            label
                .overlay {
                    if focused, enabled {
                        shape.strokeBorder(resolvedTint.opacity(0.8), lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.42)
                .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
        } else {
            label
                .shadow(
                    color: embossing.color.opacity(enabled ? 1 : 0), radius: 0,
                    y: UIScale.pt(embossing.y)
                )
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
                    SkeuoKey(depth, cornerRadius: metrics.cornerRadius, tint: keyTint)
                }
                .overlay {
                    if let border {
                        shape.strokeBorder(border, lineWidth: 2).allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .opacity(enabled ? (inactive ? 0.72 : 1) : 0.42)
                .onHover { hovering = enabled && $0 }
                .animation(
                    Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: hovering
                )
                .animation(
                    Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: pressed
                )
                .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
        }
    }

    private var tinted: Bool { role == .primary || role == .destructive }

    private var embossing: (color: Color, y: CGFloat) {
        SkeuoSkin.embossing(onTint: tinted, dark: scheme == .dark)
    }

    private var keyTint: Color? {
        switch role {
        case .primary: resolvedTint
        case .destructive: DashSkin.danger
        default: nil
        }
    }

    private var depth: SkeuoDepth {
        let live = enabled && pressed
        switch role {
        case .primary, .destructive, .secondary:
            return live ? .pressed : .raised
        case .row, .selection:
            if live { return .pressed }
            if selected { return .raised }
            return hovering ? .recessed : .flat
        case .toolbar, .iconOnly:
            if live || selected { return .pressed }
            return hovering ? .recessed : .flat
        case .borderless:
            return .flat
        }
    }

    private var foreground: Color {
        switch role {
        case .primary, .destructive:
            return .white
        case .toolbar, .iconOnly:
            return tint ?? .primary
        default:
            return .primary
        }
    }

    private var border: Color? {
        if focused, enabled { return resolvedTint.opacity(0.95) }
        if selected, differentiateWithoutColor { return Color.primary.opacity(0.75) }
        return nil
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
                .blur(radius: UIScale.pt(28))
                .overlay {
                    (dark ? Color.black : Color.white).opacity(0.45)
                        .allowsHitTesting(false)
                }
                .privacySensitive(true)
        } else {
            self
        }
    }

    public func settingsCaption() -> some View {
        font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
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
    Text(text)
        .font(.system(size: UIScale.pt(10), weight: .semibold))
        .tracking(UIScale.pt(1.4))
        .foregroundStyle(.tertiary)
}

public struct EmptyStateText: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 28)
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
