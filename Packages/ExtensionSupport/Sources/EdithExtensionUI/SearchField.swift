import SwiftUI

public struct SearchField: View {
    private let placeholder: String
    @Binding private var text: String
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    public init(placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    public var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.edithText(.body))
                .focused($focused)
                .focusEffectDisabled()
                .textEditingCommands()
                .onExitCommand { focused = false }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.edith(.borderless))
                .help("Clear this field")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, UIScale.pt(10))
        .padding(.vertical, UIScale.pt(7))
        .background(
            DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9))
        )
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(9))
                .strokeBorder(
                    focused ? DashSkin.accent(scheme == .dark) : DashSkin.line(scheme == .dark),
                    lineWidth: UIScale.pt(focused ? 1.5 : 1))
        }
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}
