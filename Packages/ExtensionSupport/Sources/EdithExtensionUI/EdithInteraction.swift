import EdithExtensionCore
import SwiftUI

public enum EdithInteractionPreview: Sendable, Hashable, CaseIterable {
    case hovered
    case pressed
}

public enum EdithHoverTone: Sendable, Hashable {
    case tinted
    case neutral
}

private struct EdithInteractionPreviewKey: EnvironmentKey {
    static let defaultValue: EdithInteractionPreview? = nil
}

extension EnvironmentValues {
    public var edithInteractionPreview: EdithInteractionPreview? {
        get { self[EdithInteractionPreviewKey.self] }
        set { self[EdithInteractionPreviewKey.self] = newValue }
    }
}

enum EdithInteractionMetrics {
    static let neutralHover = 0.08
    static let neutralPress = 0.13
    static let tintHoverLight = 0.07
    static let tintHoverDark = 0.1
    static let tintPressLight = 0.12
    static let tintPressDark = 0.16
    static let contrastBoost = 0.06
    static let contrastStroke = 0.45
    static let focusOpacity = 0.9
    static let focusWidth = 2.0
    static let compactThreshold = 28.0
    static let compactOutsetX = 4.0
    static let compactOutsetY = 2.0
    static let minimumPlate = 20.0
    static let compactCornerRadius = 6.0
    static let regularCornerRadius = 8.0
    static let disabledOpacity = 0.42

    static func neutral(pressed: Bool, increasedContrast: Bool) -> Double {
        (pressed ? neutralPress : neutralHover) + (increasedContrast ? contrastBoost : 0)
    }

    static func tint(pressed: Bool, dark: Bool, increasedContrast: Bool) -> Double {
        let base =
            pressed
            ? (dark ? tintPressDark : tintPressLight) : (dark ? tintHoverDark : tintHoverLight)
        return base + (increasedContrast ? contrastBoost : 0)
    }

    static func plateSize(for size: CGSize, scale: Double) -> CGSize {
        guard size.height < compactThreshold * scale else { return size }
        return CGSize(
            width: max(size.width + compactOutsetX * 2 * scale, minimumPlate * scale),
            height: max(size.height + compactOutsetY * 2 * scale, minimumPlate * scale))
    }

    static func cornerRadius(for size: CGSize, scale: Double) -> Double {
        size.height < compactThreshold * scale
            ? compactCornerRadius * scale : regularCornerRadius * scale
    }
}

struct EdithInteractionState: Equatable {
    var hovered: Bool
    var pressed: Bool

    static func resolve(
        hovering: Bool, pressed: Bool, enabled: Bool, preview: EdithInteractionPreview?
    ) -> Self {
        guard enabled else { return Self(hovered: false, pressed: false) }
        return Self(
            hovered: hovering || preview == .hovered || preview == .pressed,
            pressed: pressed || preview == .pressed)
    }

    var active: Bool { hovered || pressed }
}

public struct EdithHoverPlate: View {
    let hovered: Bool
    let pressed: Bool
    let tint: Color?
    let tone: EdithHoverTone
    let cornerRadius: CGFloat

    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.process.defaults())
    private var themeName = "accent"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        hovered: Bool, pressed: Bool = false, tint: Color? = nil, tone: EdithHoverTone = .tinted,
        cornerRadius: CGFloat
    ) {
        self.hovered = hovered
        self.pressed = pressed
        self.tint = tint
        self.tone = tone
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let increased = contrast == .increased
        ZStack {
            shape.fill(
                Color.primary.opacity(
                    EdithInteractionMetrics.neutral(pressed: pressed, increasedContrast: increased))
            )
            if tone == .tinted {
                shape.fill(
                    (tint ?? themeColor(themeName)).opacity(
                        EdithInteractionMetrics.tint(
                            pressed: pressed, dark: scheme == .dark, increasedContrast: increased)))
            }
            if increased {
                shape.strokeBorder(
                    Color.primary.opacity(EdithInteractionMetrics.contrastStroke), lineWidth: 1)
            }
        }
        .opacity(hovered || pressed ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct EdithFocusRing: View {
    let focused: Bool
    let tint: Color
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                tint.opacity(focused ? EdithInteractionMetrics.focusOpacity : 0),
                lineWidth: EdithInteractionMetrics.focusWidth
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct EdithOutsetHoverPlate: View {
    let state: EdithInteractionState
    let focused: Bool
    let tint: Color?
    let tone: EdithHoverTone
    let cornerRadius: CGFloat?
    let outset: Bool

    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.process.defaults())
    private var themeName = "accent"

    var body: some View {
        GeometryReader { proxy in
            let scale = UIScale.current
            let size =
                outset
                ? EdithInteractionMetrics.plateSize(for: proxy.size, scale: scale) : proxy.size
            let radius =
                cornerRadius ?? EdithInteractionMetrics.cornerRadius(for: proxy.size, scale: scale)
            ZStack {
                EdithHoverPlate(
                    hovered: state.hovered, pressed: state.pressed, tint: tint, tone: tone,
                    cornerRadius: radius)
                EdithFocusRing(
                    focused: focused, tint: tint ?? themeColor(themeName), cornerRadius: radius)
            }
            .frame(width: size.width, height: size.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

public struct EdithHoverHighlight: ViewModifier {
    let tint: Color?
    let tone: EdithHoverTone
    let cornerRadius: CGFloat?
    let outset: Bool
    let pressed: Bool

    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.edithInteractionPreview) private var preview
    @State private var hovering = false

    public init(
        tint: Color? = nil, tone: EdithHoverTone = .tinted, cornerRadius: CGFloat? = nil,
        outset: Bool = false, pressed: Bool = false
    ) {
        self.tint = tint
        self.tone = tone
        self.cornerRadius = cornerRadius
        self.outset = outset
        self.pressed = pressed
    }

    public func body(content: Content) -> some View {
        let state = EdithInteractionState.resolve(
            hovering: hovering, pressed: pressed, enabled: enabled, preview: preview)
        content
            .overlay {
                EdithOutsetHoverPlate(
                    state: state, focused: false, tint: tint, tone: tone,
                    cornerRadius: cornerRadius, outset: outset)
            }
            .onHover { hovering = $0 }
            .animation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: state)
    }
}

extension View {
    public func edithHoverHighlight(
        tint: Color? = nil, tone: EdithHoverTone = .tinted, cornerRadius: CGFloat? = nil,
        outset: Bool = false, pressed: Bool = false
    ) -> some View {
        modifier(
            EdithHoverHighlight(
                tint: tint, tone: tone, cornerRadius: cornerRadius, outset: outset,
                pressed: pressed))
    }
}
