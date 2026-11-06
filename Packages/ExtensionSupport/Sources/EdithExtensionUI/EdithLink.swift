import EdithExtensionCore
import SwiftUI

public struct EdithLinkStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        EdithLinkBody(label: configuration.label, pressed: configuration.isPressed)
    }
}

extension ButtonStyle where Self == EdithLinkStyle {
    public static var edithLink: EdithLinkStyle { EdithLinkStyle() }
}

private struct EdithLinkBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.process.defaults())
    private var themeName = "accent"
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.edithInteractionPreview) private var preview
    @State private var hovering = false

    var body: some View {
        let interaction = EdithInteractionState.resolve(
            hovering: hovering, pressed: pressed, enabled: enabled, preview: preview)
        label
            .foregroundStyle(themeColor(themeName))
            .underline(interaction.hovered || (focused && enabled))
            .overlay {
                EdithOutsetHoverPlate(
                    state: interaction, focused: focused && enabled, tint: nil, tone: .tinted,
                    cornerRadius: nil, outset: true)
            }
            .opacity(enabled ? 1 : EdithInteractionMetrics.disabledOpacity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(
                Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: interaction)
    }
}

public struct EdithLink<Label: View>: View {
    let destination: URL
    let label: Label

    public init(destination: URL, @ViewBuilder label: () -> Label) {
        self.destination = destination
        self.label = label()
    }

    public var body: some View {
        Link(destination: destination) { label }
            .buttonStyle(.edithLink)
    }
}

extension EdithLink where Label == Text {
    public init(_ title: some StringProtocol, destination: URL) {
        self.init(destination: destination) { Text(title) }
    }
}
