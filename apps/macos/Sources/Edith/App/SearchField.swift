import AppKit
import EdithKit
import SwiftUI

struct SearchField: View {
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    let placeholder: String
    @Binding var text: String
    var compact = false
    var typeAhead = false

    private var dark: Bool { scheme == .dark }
    private var fontSize: CGFloat { compact ? 11 : 12.5 }
    private var radius: CGFloat { UIScale.pt(compact ? 7 : 9) }

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: UIScale.pt(fontSize - 1)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: UIScale.pt(fontSize)))
                .focused($focused)
                .focusEffectDisabled()
                .onExitCommand { focused = false }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: UIScale.pt(fontSize)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Clear")
            }
        }
        .padding(.horizontal, UIScale.pt(compact ? 8 : 10))
        .padding(.vertical, UIScale.pt(compact ? 5 : 7))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(
                    focused ? DashSkin.accent(dark) : DashSkin.line(dark),
                    lineWidth: UIScale.pt(focused ? 1.5 : 1))
        )
        .animation(.easeOut(duration: 0.12), value: focused)
        .background(typeAheadAnchor)
    }

    @ViewBuilder
    private var typeAheadAnchor: some View {
        if typeAhead {
            TypeAheadAnchor()
        }
    }
}

private struct TypeAheadAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let anchor = NSView(frame: .zero)
        TypeAhead.shared.register(anchor: anchor)
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        TypeAhead.shared.register(anchor: nsView)
    }
}
