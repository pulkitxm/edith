import AppKit
import EdithExtensionCore
import SwiftUI

struct EdithFieldSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let focused: Bool
    var compact = false
    var invalid = false

    private var dark: Bool { scheme == .dark }
    private var radius: CGFloat { UIScale.pt(compact ? 7 : 9) }

    private var border: Color {
        if invalid { return DashSkin.danger }
        return focused ? DashSkin.accent(dark) : DashSkin.line(dark)
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, UIScale.pt(compact ? 8 : 10))
            .padding(.vertical, UIScale.pt(compact ? 5 : 7))
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(border, lineWidth: UIScale.pt(focused || invalid ? 1.5 : 1))
            )
            .animation(
                Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: focused)
    }
}

extension View {
    public func edithFieldSurface(focused: Bool, compact: Bool = false, invalid: Bool = false)
        -> some View
    {
        modifier(EdithFieldSurface(focused: focused, compact: compact, invalid: invalid))
    }
}

public struct EdithTextField: View {
    @Environment(\.colorScheme) private var scheme
    @FocusState private var localFocus: Bool

    let placeholder: String
    @Binding var text: String
    var icon: String?
    var font: Font?
    var alignment: TextAlignment = .leading
    var compact = false
    var clearable = false
    var typeAhead = false
    var searchable = false
    var invalid = false
    var focus: FocusState<Bool>.Binding?
    var onSubmit: (() -> Void)?

    public init(
        placeholder: String, text: Binding<String>, icon: String? = nil,
        font: Font? = nil, alignment: TextAlignment = .leading, compact: Bool = false,
        clearable: Bool = false, typeAhead: Bool = false, searchable: Bool = false,
        invalid: Bool = false,
        focus: FocusState<Bool>.Binding? = nil, onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder; _text = text; self.icon = icon; self.font = font
        self.alignment = alignment; self.compact = compact; self.clearable = clearable
        self.typeAhead = typeAhead; self.searchable = searchable; self.invalid = invalid
        self.focus = focus; self.onSubmit = onSubmit
    }

    private var dark: Bool { scheme == .dark }
    private var fontSize: CGFloat { compact ? 11 : 12.5 }
    private var focused: Bool { focus?.wrappedValue ?? localFocus }

    public var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: UIScale.pt(fontSize - 1)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            field
            if clearable, !text.isEmpty {
                Button {
                    text = ""
                    (focus ?? $localFocus).wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: UIScale.pt(fontSize)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: UIScale.pt(20), height: UIScale.pt(20))
                }
                .buttonStyle(.edith(.borderless))
                .help("Clear this field")
                .accessibilityLabel("Clear \(placeholder)")
            }
        }
        .edithFieldSurface(focused: focused, compact: compact, invalid: invalid)
        .background(typeAheadAnchor)
    }

    private var field: some View {
        TextField(
            placeholder, text: $text,
            prompt: Text(placeholder).foregroundColor(DashSkin.inkFaint(dark))
        )
        .textFieldStyle(.plain)
        .labelsHidden()
        .font(font ?? .system(size: UIScale.pt(fontSize)))
        .foregroundStyle(DashSkin.ink(dark))
        .multilineTextAlignment(alignment)
        .focused(focus ?? $localFocus)
        .focusEffectDisabled()
        .textEditingCommands()
        .onExitCommand {
            if searchable, !text.isEmpty {
                text = ""
            } else {
                (focus ?? $localFocus).wrappedValue = false
            }
        }
        .onSubmit { onSubmit?() }
    }

    @ViewBuilder
    private var typeAheadAnchor: some View {
        if typeAhead || searchable {
            TypeAheadAnchor(typeAhead: typeAhead)
        }
    }
}

public struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var compact = false
    var typeAhead = false
    var focus: FocusState<Bool>.Binding?

    public init(
        placeholder: String, text: Binding<String>, compact: Bool = false,
        typeAhead: Bool = false, focus: FocusState<Bool>.Binding? = nil
    ) {
        self.placeholder = placeholder; _text = text; self.compact = compact
        self.typeAhead = typeAhead; self.focus = focus
    }

    public var body: some View {
        EdithTextField(
            placeholder: placeholder, text: $text, icon: "magnifyingglass", compact: compact,
            clearable: true, typeAhead: typeAhead, searchable: true, focus: focus)
    }
}

public struct EdithSecureField: View {
    @Environment(\.colorScheme) private var scheme
    @FocusState private var localFocus: Bool

    let placeholder: String
    @Binding var text: String
    var icon: String?
    var compact = false
    var invalid = false
    var focus: FocusState<Bool>.Binding?
    var onSubmit: (() -> Void)?

    public init(
        placeholder: String, text: Binding<String>, icon: String? = nil, compact: Bool = false,
        invalid: Bool = false, focus: FocusState<Bool>.Binding? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder; _text = text; self.icon = icon; self.compact = compact
        self.invalid = invalid; self.focus = focus; self.onSubmit = onSubmit
    }

    private var dark: Bool { scheme == .dark }
    private var fontSize: CGFloat { compact ? 11 : 12.5 }

    public var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: UIScale.pt(fontSize - 1)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            SecureField(
                placeholder, text: $text,
                prompt: Text(placeholder).foregroundColor(DashSkin.inkFaint(dark))
            )
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(.system(size: UIScale.pt(fontSize)))
            .foregroundStyle(DashSkin.ink(dark))
            .focused(focus ?? $localFocus)
            .focusEffectDisabled()
            .textEditingCommands()
            .onExitCommand { (focus ?? $localFocus).wrappedValue = false }
            .onSubmit { onSubmit?() }
        }
        .edithFieldSurface(
            focused: focus?.wrappedValue ?? localFocus, compact: compact, invalid: invalid)
    }
}

public struct EdithNumberField: View {
    @FocusState private var focused: Bool

    @Binding var value: Int
    var width: CGFloat
    var grouped = true

    public init(value: Binding<Int>, width: CGFloat, grouped: Bool = true) {
        _value = value
        self.width = width
        self.grouped = grouped
    }

    public var body: some View {
        TextField("", value: $value, format: .number.grouping(grouped ? .automatic : .never))
            .textFieldStyle(.plain)
            .font(.system(size: UIScale.pt(12.5)))
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .focused($focused)
            .focusEffectDisabled()
            .textEditingCommands()
            .onExitCommand { focused = false }
            .frame(width: width)
            .edithFieldSurface(focused: focused, compact: true)
    }
}

public struct EdithCheckboxStyle: ToggleStyle {
    let showsLabel: Bool

    public init(showsLabel: Bool = true) {
        self.showsLabel = showsLabel
    }

    public func makeBody(configuration: Configuration) -> some View {
        EdithCheckboxBody(configuration: configuration, showsLabel: showsLabel)
    }
}

extension ToggleStyle where Self == EdithCheckboxStyle {
    public static var edithCheckbox: EdithCheckboxStyle { EdithCheckboxStyle() }
    public static var edithCheckboxMark: EdithCheckboxStyle { EdithCheckboxStyle(showsLabel: false) }
}

private struct EdithCheckboxBody: View {
    let configuration: ToggleStyleConfiguration
    let showsLabel: Bool
    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.process.defaults())
    private var themeName = "accent"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    private var marked: Bool { configuration.isOn || configuration.isMixed }

    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: UIScale.pt(4), style: .continuous)
        let accent = themeColor(themeName)
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                ZStack {
                    shape.fill(marked ? accent : DashSkin.paper2(dark))
                    shape.strokeBorder(
                        focused ? accent : marked ? accent : DashSkin.lineStrong(dark),
                        lineWidth: focused ? 2 : UIScale.pt(1))
                    if marked {
                        Image(systemName: configuration.isMixed ? "minus" : "checkmark")
                            .font(.system(size: UIScale.pt(9), weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: UIScale.pt(16), height: UIScale.pt(16))
                .accessibilityHidden(true)
                if showsLabel {
                    configuration.label
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

public struct EdithCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    public var body: some View {
        Toggle(title, isOn: $isOn).toggleStyle(.edithCheckbox).font(.edithText(.body))
    }
}

private struct TypeAheadAnchor: NSViewRepresentable {
    let typeAhead: Bool

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView(frame: .zero)
        TypeAhead.shared.register(anchor: anchor, typeAhead: typeAhead)
        return anchor
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        TypeAhead.shared.unregister(anchor: nsView)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        TypeAhead.shared.register(anchor: nsView, typeAhead: typeAhead)
    }
}
