import EdithIcons
import SwiftUI

extension View {
    public func borderlessMenu() -> some View {
        menuStyle(.button).buttonStyle(BorderlessMenuButtonStyle())
    }
}

enum BorderlessMenuMetrics {
    static let horizontalPadding: CGFloat = 3
    static let indicatorSpacing: CGFloat = 1
    static let indicatorSize: CGFloat = 12
    static let disabledOpacity = 0.5
}

private struct BorderlessMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BorderlessMenuLabel(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct BorderlessMenuLabel<Label: View>: View {
    let label: Label
    let pressed: Bool

    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.menuIndicatorVisibility) private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.edithInteractionPreview) private var preview
    @State private var hovering = false

    private var interaction: EdithInteractionState {
        EdithInteractionState.resolve(
            hovering: hovering, pressed: pressed, enabled: enabled, preview: preview)
    }

    var body: some View {
        HStack(spacing: UIScale.pt(BorderlessMenuMetrics.indicatorSpacing)) {
            label
            if indicator != .hidden {
                EdithIconView(.chevronDown, size: UIScale.pt(BorderlessMenuMetrics.indicatorSize))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, UIScale.pt(BorderlessMenuMetrics.horizontalPadding))
        .foregroundStyle(.tint, .secondary, .tertiary)
        .overlay {
            EdithOutsetHoverPlate(
                state: interaction, focused: focused && enabled, tint: nil, tone: .tinted,
                cornerRadius: nil, outset: true)
        }
        .opacity(enabled ? 1 : BorderlessMenuMetrics.disabledOpacity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(
            Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: interaction)
    }
}
