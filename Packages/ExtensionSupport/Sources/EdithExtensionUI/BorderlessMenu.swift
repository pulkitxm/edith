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
    static let pressedOpacity = 0.7
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
    @Environment(\.menuIndicatorVisibility) private var indicator

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
        .opacity(opacity)
        .contentShape(Rectangle())
    }

    private var opacity: Double {
        if !enabled { return BorderlessMenuMetrics.disabledOpacity }
        return pressed ? BorderlessMenuMetrics.pressedOpacity : 1
    }
}
