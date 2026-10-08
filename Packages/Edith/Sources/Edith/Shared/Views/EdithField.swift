import AppKit
import EdithKit
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
    func edithFieldSurface(focused: Bool, compact: Bool = false, invalid: Bool = false) -> some View
    {
        modifier(EdithFieldSurface(focused: focused, compact: compact, invalid: invalid))
    }
}

struct EdithTextField: View {
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

    private var dark: Bool { scheme == .dark }
    private var fontSize: CGFloat { compact ? 11 : 12.5 }
    private var focused: Bool { focus?.wrappedValue ?? localFocus }

    var body: some View {
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
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
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

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var compact = false
    var typeAhead = false
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        EdithTextField(
            placeholder: placeholder, text: $text, icon: "magnifyingglass", compact: compact,
            clearable: true, typeAhead: typeAhead, searchable: true, focus: focus)
    }
}

struct EdithNumberField: View {
    @FocusState private var focused: Bool

    @Binding var value: Int
    var width: CGFloat

    var body: some View {
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
    let typeAhead: Bool
    func makeNSView(context: Context) -> NSView {
        let anchor = NSView(frame: .zero)
        TypeAhead.shared.register(anchor: anchor, typeAhead: typeAhead)
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        TypeAhead.shared.register(anchor: nsView, typeAhead: typeAhead)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        TypeAhead.shared.unregister(anchor: nsView)
    }
}
