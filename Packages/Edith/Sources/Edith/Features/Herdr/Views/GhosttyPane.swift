import EdithKit
import GhosttyTerminal
import SwiftUI

extension GhosttyTerminalView: DirectKeyboardInputResponder, DirectScrollHandling {}

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

struct GhosttyPane: NSViewRepresentable {
    let holder: TerminalSessionHolder
    let launch: GhosttyLaunch
    let theme: GhosttyTheme
    var active = true
    var wantsFocus = true
    var onDropFiles: ((TerminalDropPayload) -> Bool)?
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
        let view = holder.retainedGhosttyView(launch: launch, theme: theme)
        view.onDropFiles = onDropFiles
        view.onFocus = onFocus
        view.setRenderingActive(active)
        return view
    }

    func updateNSView(_ view: GhosttyTerminalView, context: Context) {
        view.apply(theme: theme)
        view.onDropFiles = onDropFiles
        view.onFocus = onFocus
        view.setRenderingActive(active)
        guard context.coordinator.shouldRequest(active: active, wantsFocus: wantsFocus) else {
            return
        }
        DispatchQueue.main.async { view.focusIfNeeded() }
    }
}
