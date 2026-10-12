import AppKit
import SwiftUI

struct EdithFieldSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

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
            .animation(.easeOut(duration: 0.12), value: focused)
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
    var invalid = false
    var focus: FocusState<Bool>.Binding?
    var onSubmit: (() -> Void)?

    public init(
        placeholder: String, text: Binding<String>, icon: String? = nil,
        font: Font? = nil, alignment: TextAlignment = .leading, compact: Bool = false,
        clearable: Bool = false, typeAhead: Bool = false, invalid: Bool = false,
        focus: FocusState<Bool>.Binding? = nil, onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder; _text = text; self.icon = icon; self.font = font
        self.alignment = alignment; self.compact = compact; self.clearable = clearable
        self.typeAhead = typeAhead; self.invalid = invalid; self.focus = focus;
        self.onSubmit = onSubmit
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
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: UIScale.pt(fontSize)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                .buttonStyle(.edith(.borderless))
                .help("Clear this field")
            }
        }
        .edithFieldSurface(focused: focused, compact: compact, invalid: invalid)
        .background(typeAheadAnchor)
    }

    private var field: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font ?? .system(size: UIScale.pt(fontSize)))
            .foregroundStyle(DashSkin.ink(dark))
            .multilineTextAlignment(alignment)
            .focused(focus ?? $localFocus)
            .focusEffectDisabled()
            .textEditingCommands()
            .onExitCommand { (focus ?? $localFocus).wrappedValue = false }
            .onSubmit { onSubmit?() }
    }

    @ViewBuilder
    private var typeAheadAnchor: some View {
        if typeAhead {
            TypeAheadAnchor()
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
            clearable: true, typeAhead: typeAhead, focus: focus)
    }
}

public struct EdithNumberField: View {
    @FocusState private var focused: Bool

    @Binding var value: Int
    var width: CGFloat

    public init(value: Binding<Int>, width: CGFloat) { _value = value; self.width = width }

    public var body: some View {
        TextField("", value: $value, format: .number)
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

private struct TypeAheadAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let anchor = NSView(frame: .zero)
        TypeAhead.shared.register(anchor: anchor)
        return anchor
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        TypeAhead.shared.unregister(anchor: nsView)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        TypeAhead.shared.register(anchor: nsView)
    }
}
