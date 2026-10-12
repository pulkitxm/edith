import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import GhosttyTerminal
import SwiftUI

extension GhosttyTerminalView: @retroactive DirectKeyboardInputResponder {}

extension GhosttyTheme {
    init(palette: TerminalPalette, fontSize: Double? = nil) {
        self.init(
            background: palette.background,
            foreground: palette.foreground,
            cursor: palette.caret,
            selectionBackground: palette.selectionBackground,
            selectionForeground: palette.selectionForeground,
            palette: palette.ansi,
            fontSize: fontSize)
    }
}

struct TerminalPane: View {
    let holder: TerminalSessionHolder
    let palette: TerminalPalette
    var active = true
    var wantsFocus = true
    var onFocus: (() -> Void)?

    var body: some View {
        if holder.started {
            GhosttyPane(
                holder: holder,
                theme: GhosttyTheme(
                    palette: palette,
                    fontSize: TerminalSettings.clampedFontSize(holder.fontSize)),
                active: active, wantsFocus: wantsFocus, onFocus: onFocus
            )
            .id(holder.generation)
        }
    }
}

struct GhosttyPane: NSViewRepresentable {
    let holder: TerminalSessionHolder
    let theme: GhosttyTheme
    var active = true
    var wantsFocus = true
    var onFocus: (() -> Void)?

    final class Coordinator {
        private var requested = false

        func shouldRequest(active: Bool, wantsFocus: Bool) -> Bool {
            let next = active && wantsFocus
            defer { requested = next }
            return next && !requested
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GhosttyTerminalView {
        let view = holder.retainedGhosttyView(theme: theme)
        view.onFocus = onFocus
        view.setRenderingActive(active)
        return view
    }

    func updateNSView(_ view: GhosttyTerminalView, context: Context) {
        view.apply(theme: theme)
        view.onFocus = onFocus
        view.setRenderingActive(active)
        if context.coordinator.shouldRequest(active: active, wantsFocus: wantsFocus) {
            view.requestFocus()
        } else if !(active && wantsFocus) {
            view.cancelFocusRequest()
        }
    }
}
