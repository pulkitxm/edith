import EdithExtensionCore
import EdithIcons
import SwiftUI

enum EdithSplitButtonSegment: Sendable, Hashable {
    case action
    case menu
}

enum EdithSplitButtonMetrics {
    static let button = EdithButtonMetrics.metrics(for: .secondary)
    static let chevronSize = 12.0
    static var menuWidth: Double { button.minimumHeight }
    static let increasedContrastDivider = 1.0

    static func dividerWidth(displayScale: CGFloat, increasedContrast: Bool) -> CGFloat {
        increasedContrast ? increasedContrastDivider : 1 / max(displayScale, 1)
    }

    static func shape(for segment: EdithSplitButtonSegment, cornerRadius: CGFloat)
        -> UnevenRoundedRectangle
    {
        switch segment {
        case .action:
            UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius, bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        case .menu:
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: cornerRadius, topTrailingRadius: cornerRadius,
                style: .continuous)
        }
    }
}

public struct EdithSplitButton<Label: View, MenuContent: View>: View {
    let role: EdithButtonRole
    let tint: Color?
    let actionAccessibilityLabel: String?
    let menuAccessibilityLabel: String
    let actionHelp: String?
    let menuHelp: String?
    let action: () -> Void
    let label: Label
    let menuContent: MenuContent

    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.process.defaults())
    private var themeName = AppTheme.standard.rawValue

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isEnabled) private var enabled

    public init(
        _ role: EdithButtonRole = .secondary, tint: Color? = nil,
        actionAccessibilityLabel: String? = nil, menuAccessibilityLabel: String,
        actionHelp: String? = nil, menuHelp: String? = nil,
        action: @escaping () -> Void, @ViewBuilder label: () -> Label,
        @ViewBuilder menu: () -> MenuContent
    ) {
        self.role = role
        self.tint = tint
        self.actionAccessibilityLabel = actionAccessibilityLabel
        self.menuAccessibilityLabel = menuAccessibilityLabel
        self.actionHelp = actionHelp
        self.menuHelp = menuHelp
        self.action = action
        self.label = label()
        self.menuContent = menu()
    }

    private var palette: EdithButtonPalette {
        EdithButtonPalette(
            role: role, selected: false, tint: tint, themeName: themeName,
            dark: scheme == .dark, increasedContrast: contrast == .increased,
            differentiateWithoutColor: differentiateWithoutColor)
    }

    private var dividerColor: Color {
        let border = palette.border(focused: false)
        return border == .clear
            ? Color.primary.opacity(contrast == .increased ? 0.34 : 0.18) : border
    }

    public var body: some View {
        let palette = palette
        let cornerRadius = UIScale.pt(EdithSplitButtonMetrics.button.cornerRadius)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        HStack(spacing: 0) {
            Button(action: action) { label }
                .buttonStyle(
                    EdithSplitSegmentStyle(
                        segment: .action, palette: palette, cornerRadius: cornerRadius)
                )
                .edithSplitHelp(actionHelp)
                .edithSplitAccessibilityLabel(actionAccessibilityLabel)
            Rectangle()
                .fill(dividerColor)
                .frame(
                    width: EdithSplitButtonMetrics.dividerWidth(
                        displayScale: displayScale, increasedContrast: contrast == .increased)
                )
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Menu {
                menuContent
            } label: {
                SwiftUI.Label {
                    Text(menuAccessibilityLabel)
                } icon: {
                    EdithIcon.chevronDown.image(
                        size: UIScale.pt(EdithSplitButtonMetrics.chevronSize))
                }
                .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(
                EdithSplitSegmentStyle(segment: .menu, palette: palette, cornerRadius: cornerRadius)
            )
            .menuIndicator(.hidden)
            .edithSplitHelp(menuHelp)
            .accessibilityLabel(menuAccessibilityLabel)
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(palette.foreground)
        .background(shape.fill(palette.background))
        .overlay(
            shape.strokeBorder(
                palette.border(focused: false), lineWidth: palette.borderWidth(focused: false)
            )
            .allowsHitTesting(false)
        )
        .opacity(
            enabled
                ? (activeState == .inactive ? 0.72 : 1) : EdithInteractionMetrics.disabledOpacity
        )
        .accessibilityElement(children: .contain)
    }
}

extension EdithSplitButton where Label == Text {
    public init(
        _ title: String, role: EdithButtonRole = .secondary, tint: Color? = nil,
        actionAccessibilityLabel: String? = nil, menuAccessibilityLabel: String,
        actionHelp: String? = nil, menuHelp: String? = nil,
        action: @escaping () -> Void, @ViewBuilder menu: () -> MenuContent
    ) {
        self.init(
            role, tint: tint, actionAccessibilityLabel: actionAccessibilityLabel,
            menuAccessibilityLabel: menuAccessibilityLabel, actionHelp: actionHelp,
            menuHelp: menuHelp, action: action, label: { Text(title) }, menu: menu)
    }
}

struct EdithSplitSegmentStyle: ButtonStyle {
    let segment: EdithSplitButtonSegment
    let palette: EdithButtonPalette
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        EdithSplitSegmentBody(
            label: configuration.label, segment: segment, palette: palette,
            cornerRadius: cornerRadius, pressed: configuration.isPressed)
    }
}

private struct EdithSplitSegmentBody<Label: View>: View {
    let label: Label
    let segment: EdithSplitButtonSegment
    let palette: EdithButtonPalette
    let cornerRadius: CGFloat
    let pressed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        let metrics = EdithSplitButtonMetrics.button
        let shape = EdithSplitButtonMetrics.shape(for: segment, cornerRadius: cornerRadius)
        let menuWidth = UIScale.pt(EdithSplitButtonMetrics.menuWidth)
        let horizontal = segment == .action ? UIScale.pt(metrics.horizontalPadding) : 0
        let vertical = segment == .action ? UIScale.pt(metrics.verticalPadding) : 0
        label
            .font(font ?? .edithText(.body))
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .frame(
                minWidth: segment == .menu ? menuWidth : UIScale.pt(metrics.minimumWidth),
                maxWidth: segment == .menu ? menuWidth : nil,
                minHeight: UIScale.pt(metrics.minimumHeight),
                maxHeight: .infinity
            )
            .background {
                EdithHoverPlate(
                    hovered: interaction.active, pressed: interaction.pressed,
                    tint: palette.tint, tone: palette.plateTone, cornerRadius: 0
                )
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(
                    palette.resolvedTint.opacity(
                        focused && enabled ? EdithInteractionMetrics.focusOpacity : 0),
                    lineWidth: EdithInteractionMetrics.focusWidth
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .contentShape(shape)
            .edithHoverTracking($hovering)
            .animation(
                Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: interaction)
    }
}

extension View {
    @ViewBuilder
    fileprivate func edithSplitHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }

    @ViewBuilder
    fileprivate func edithSplitAccessibilityLabel(_ text: String?) -> some View {
        if let text { accessibilityLabel(text) } else { self }
    }
}
