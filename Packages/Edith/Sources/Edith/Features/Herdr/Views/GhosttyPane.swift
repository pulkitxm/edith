import GhosttyTerminal
import SwiftUI

extension GhosttyTheme {
    init(palette: TerminalPalette, fontSize: Double? = nil) {
        self.init(
            background: palette.background,
            foreground: palette.foreground,
            cursor: palette.caret,
            selectionBackground: palette.foreground,
            selectionForeground: palette.background,
            fontSize: fontSize)
    }
}

struct GhosttyPane: NSViewRepresentable {
    let launch: GhosttyLaunch
    let theme: GhosttyTheme
    var active = true
    var wantsFocus = true
    var onClose: (() -> Void)?

    func makeNSView(context: Context) -> GhosttyTerminalView {
        let view = GhosttyTerminalView(launch: launch, theme: theme)
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: GhosttyTerminalView, context: Context) {
        view.onClose = onClose
        view.apply(theme: theme)
        guard active, wantsFocus else { return }
        DispatchQueue.main.async { view.focusIfNeeded() }
    }
}
