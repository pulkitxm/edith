import SwiftUI

public struct EdithSegmentedPicker<Selection: Hashable>: View {
    private let title: String
    @Binding private var selection: Selection
    private let options: [Selection]
    private let label: (Selection) -> String
    private let shortcut: (Selection) -> KeyboardShortcut?

    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = "accent"
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        _ title: String,
        selection: Binding<Selection>,
        options: [Selection],
        label: @escaping (Selection) -> String,
        shortcut: @escaping (Selection) -> KeyboardShortcut? = { _ in nil }
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
        self.shortcut = shortcut
    }

    public var body: some View {
        HStack(spacing: UIScale.pt(3)) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: UIScale.pt(11), weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .padding(.horizontal, UIScale.pt(5))
                        .frame(height: UIScale.pt(28))
                        .foregroundStyle(selection == option ? themeColor(themeName) : .primary)
                        .background {
                            if selection == option {
                                RoundedRectangle(cornerRadius: UIScale.pt(6))
                                    .fill(themeColor(themeName).opacity(0.16))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.edith(.borderless))
                .keyboardShortcut(shortcut(option))
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(selection == option ? .isSelected : [])
                .help(label(option))
            }
        }
        .padding(UIScale.pt(3))
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(9))
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .opacity(enabled ? 1 : 0.45)
        .animation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard enabled, let index = options.firstIndex(of: selection), !options.isEmpty
            else { return .ignored }
            let step = press.key == .leftArrow ? -1 : 1
            selection = options[(index + step + options.count) % options.count]
            return .handled
        }
    }
}
