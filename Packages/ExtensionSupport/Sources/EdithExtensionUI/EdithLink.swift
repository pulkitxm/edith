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
    @State private var hovering = false

    var body: some View {
        label
            .foregroundStyle(themeColor(themeName))
            .underline(hovering || focused)
            .opacity(enabled ? (pressed ? 0.7 : 1) : 0.42)
            .contentShape(Rectangle())
            .onHover { hovering = enabled && $0 }
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
