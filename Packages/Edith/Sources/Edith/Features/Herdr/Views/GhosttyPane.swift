import GhosttyTerminal
import SwiftUI

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

    func makeNSView(context: Context) -> GhosttyTerminalView {
        let view = holder.retainedGhosttyView(launch: launch, theme: theme)
        view.onDropFiles = onDropFiles
        view.setRenderingActive(active)
        return view
    }

    func updateNSView(_ view: GhosttyTerminalView, context: Context) {
        view.apply(theme: theme)
        view.onDropFiles = onDropFiles
        view.setRenderingActive(active)
        guard active, wantsFocus else { return }
        DispatchQueue.main.async { view.focusIfNeeded() }
    }
}
