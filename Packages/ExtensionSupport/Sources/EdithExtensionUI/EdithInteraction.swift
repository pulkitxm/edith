import AppKit
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

private struct EdithDenseHoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var edithInteractionPreview: EdithInteractionPreview? {
        get { self[EdithInteractionPreviewKey.self] }
        set { self[EdithInteractionPreviewKey.self] = newValue }
    }

    public var edithDenseHover: Bool {
        get { self[EdithDenseHoverKey.self] }
        set { self[EdithDenseHoverKey.self] = newValue }
    }
}

enum EdithInteractionMetrics {
    static let neutralHoverLight = 0.1
    static let neutralHoverDark = 0.12
    static let neutralPressLight = 0.16
    static let neutralPressDark = 0.19
    static let tintHoverLight = 0.1
    static let tintHoverDark = 0.14
    static let tintPressLight = 0.16
    static let tintPressDark = 0.22
    static let contrastBoost = 0.06
    static let contrastStroke = 0.45
    static let hoverStrokeLight = 0.07
    static let hoverStrokeDark = 0.1
    static let focusOpacity = 0.9
    static let focusWidth = 2.0
    static let compactThreshold = 28.0
    static let compactOutsetX = 4.0
    static let compactOutsetY = 2.0
    static let minimumPlate = 20.0
    static let compactCornerRadius = 6.0
    static let regularCornerRadius = 8.0
    static let disabledOpacity = 0.42
    static let filledHoverBrightness = 0.08
    static let filledPressBrightness = -0.07
    static let filledContrastBoost = 0.05

    static func neutral(pressed: Bool, dark: Bool, increasedContrast: Bool) -> Double {
        let base =
            pressed
            ? (dark ? neutralPressDark : neutralPressLight)
            : (dark ? neutralHoverDark : neutralHoverLight)
        return base + (increasedContrast ? contrastBoost : 0)
    }

    static func filledBrightness(_ state: EdithInteractionState, increasedContrast: Bool) -> Double
    {
        let boost = increasedContrast ? filledContrastBoost : 0
        if state.pressed { return filledPressBrightness - boost }
        return state.hovered ? filledHoverBrightness + boost : 0
    }

    static func stroke(dark: Bool, increasedContrast: Bool) -> Double {
        increasedContrast ? contrastStroke : (dark ? hoverStrokeDark : hoverStrokeLight)
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
    private var themeName = AppTheme.standard.rawValue
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
        let dark = scheme == .dark
        ZStack {
            shape.fill(
                Color.primary.opacity(
                    EdithInteractionMetrics.neutral(
                        pressed: pressed, dark: dark, increasedContrast: increased))
            )
            if tone == .tinted {
                shape.fill(
                    (tint ?? themeColor(themeName)).opacity(
                        EdithInteractionMetrics.tint(
                            pressed: pressed, dark: dark, increasedContrast: increased)))
            }
            shape.strokeBorder(
                Color.primary.opacity(
                    EdithInteractionMetrics.stroke(dark: dark, increasedContrast: increased)),
                lineWidth: increased ? 1 : 0.5)
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
    private var themeName = AppTheme.standard.rawValue

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
            .edithHoverTracking($hovering)
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

final class EdithHoverTrackingView: NSView {
    var changed: ((Bool) -> Void)?
    private(set) var inside = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self))
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func viewDidHide() {
        super.viewDidHide()
        set(false)
    }

    override func mouseEntered(with event: NSEvent) { locate(event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { locate(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { set(false) }

    func refresh() {
        guard let window, !isHiddenOrHasHiddenAncestor else {
            set(false)
            return
        }
        locate(window.mouseLocationOutsideOfEventStream)
    }

    private func locate(_ location: NSPoint) {
        guard window != nil, !isHiddenOrHasHiddenAncestor else {
            set(false)
            return
        }
        let point = convert(location, from: nil)
        set(visibleRect.contains(point) && bounds.contains(point))
    }

    private func set(_ value: Bool) {
        guard value != inside else { return }
        inside = value
        changed?(value)
    }
}

struct EdithHoverTracker: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> EdithHoverTrackingView {
        let view = EdithHoverTrackingView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: EdithHoverTrackingView, context: Context) {
        view.changed = changed
    }

    static func dismantleNSView(_ view: EdithHoverTrackingView, coordinator: ()) {
        view.changed = nil
    }
}

private struct EdithHoverTracking: ViewModifier {
    @Binding var hovering: Bool
    @State private var swiftUI = false
    @State private var appKit = false
    @Environment(\.edithDenseHover) private var dense

    func body(content: Content) -> some View {
        content
            .onHover { swiftUI = $0 }
            .background {
                if !dense {
                    EdithHoverTracker { appKit = $0 }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: swiftUI || appKit, initial: true) { _, value in
                if hovering != value { hovering = value }
            }
    }
}

extension View {
    public func edithHoverTracking(_ hovering: Binding<Bool>) -> some View {
        modifier(EdithHoverTracking(hovering: hovering))
    }
}

public struct EdithControlButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        EdithControlButtonBody(label: configuration.label)
    }
}

private struct EdithControlButtonBody<Label: View>: View {
    let label: Label
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        label
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : EdithInteractionMetrics.disabledOpacity)
    }
}

extension ButtonStyle where Self == EdithControlButtonStyle {
    public static var edithControl: EdithControlButtonStyle { EdithControlButtonStyle() }
}

public struct EdithDefaultButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        BorderedButtonStyle().makeBody(configuration: configuration)
            .edithHoverHighlight(tone: .neutral, cornerRadius: UIScale.pt(6))
    }
}

extension PrimitiveButtonStyle where Self == EdithDefaultButtonStyle {
    public static var edithDefault: EdithDefaultButtonStyle { EdithDefaultButtonStyle() }
}

public struct EdithShapePlate<S: Shape>: View {
    let shape: S
    let hovered: Bool
    let pressed: Bool
    let tint: Color?

    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.process.defaults())
    private var themeName = AppTheme.standard.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ shape: S, hovered: Bool, pressed: Bool = false, tint: Color? = nil) {
        self.shape = shape
        self.hovered = hovered
        self.pressed = pressed
        self.tint = tint
    }

    public var body: some View {
        let dark = scheme == .dark
        let increased = contrast == .increased
        ZStack {
            shape.fill(
                Color.primary.opacity(
                    EdithInteractionMetrics.neutral(
                        pressed: pressed, dark: dark, increasedContrast: increased)))
            shape.fill(
                (tint ?? themeColor(themeName)).opacity(
                    EdithInteractionMetrics.tint(
                        pressed: pressed, dark: dark, increasedContrast: increased)))
            shape.stroke(
                Color.primary.opacity(
                    EdithInteractionMetrics.stroke(dark: dark, increasedContrast: increased)),
                lineWidth: increased ? 1 : 0.5)
        }
        .opacity(hovered || pressed ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

public struct EdithShapedButtonStyle<S: Shape>: ButtonStyle {
    let shape: S
    let filled: Bool
    let tint: Color?

    public init(_ shape: S, filled: Bool = false, tint: Color? = nil) {
        self.shape = shape
        self.filled = filled
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        EdithShapedButtonBody(
            label: configuration.label, shape: shape, filled: filled, tint: tint,
            pressed: configuration.isPressed)
    }
}

extension ButtonStyle {
    public static func edithShaped<S: Shape>(
        _ shape: S, filled: Bool = false, tint: Color? = nil
    ) -> EdithShapedButtonStyle<S> where Self == EdithShapedButtonStyle<S> {
        EdithShapedButtonStyle(shape, filled: filled, tint: tint)
    }
}

private struct EdithShapedButtonBody<Label: View, S: Shape>: View {
    let label: Label
    let shape: S
    let filled: Bool
    let tint: Color?
    let pressed: Bool

    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.process.defaults())
    private var themeName = AppTheme.standard.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.edithInteractionPreview) private var preview
    @Environment(\.font) private var font
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    private var interaction: EdithInteractionState {
        EdithInteractionState.resolve(
            hovering: hovering, pressed: pressed, enabled: enabled, preview: preview)
    }

    var body: some View {
        let state = interaction
        label
            .font(font ?? .edithText(.body))
            .brightness(
                filled
                    ? EdithInteractionMetrics.filledBrightness(
                        state, increasedContrast: contrast == .increased) : 0
            )
            .background {
                if !filled {
                    EdithShapePlate(
                        shape, hovered: state.hovered, pressed: state.pressed, tint: tint)
                }
            }
            .overlay {
                shape
                    .stroke(
                        (tint ?? themeColor(themeName)).opacity(
                            focused && enabled ? EdithInteractionMetrics.focusOpacity : 0),
                        lineWidth: EdithInteractionMetrics.focusWidth
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(shape)
            .opacity(enabled ? 1 : EdithInteractionMetrics.disabledOpacity)
            .edithHoverTracking($hovering)
            .animation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: state)
    }
}

public struct EdithBlockButtonStyle: ButtonStyle {
    let inset: Double

    public init(inset: Double = 6) {
        self.inset = inset
    }

    public func makeBody(configuration: Configuration) -> some View {
        EdithBlockButtonBody(
            label: configuration.label, inset: inset, pressed: configuration.isPressed)
    }
}

extension ButtonStyle where Self == EdithBlockButtonStyle {
    public static var edithBlock: EdithBlockButtonStyle { EdithBlockButtonStyle() }

    public static func edithBlock(inset: Double) -> EdithBlockButtonStyle {
        EdithBlockButtonStyle(inset: inset)
    }
}

private struct EdithBlockButtonBody<Label: View>: View {
    let label: Label
    let inset: Double
    let pressed: Bool

    @Environment(\.isEnabled) private var enabled

    var body: some View {
        label
            .padding(UIScale.pt(inset))
            .contentShape(Rectangle())
            .background {
                EdithBlockPlate(pressed: pressed)
            }
            .padding(-UIScale.pt(inset))
            .opacity(enabled ? 1 : EdithInteractionMetrics.disabledOpacity)
    }
}

private struct EdithBlockPlate: View {
    let pressed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.edithInteractionPreview) private var preview
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let state = EdithInteractionState.resolve(
            hovering: hovering, pressed: pressed, enabled: enabled, preview: preview)
        EdithHoverPlate(
            hovered: state.hovered, pressed: state.pressed, tone: .neutral,
            cornerRadius: UIScale.pt(EdithInteractionMetrics.regularCornerRadius)
        )
        .edithHoverTracking($hovering)
        .animation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: state)
    }
}
