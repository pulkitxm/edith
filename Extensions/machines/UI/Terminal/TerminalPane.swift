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
    var onDropFiles: ((TerminalDropPayload) -> Bool)?
    var onFocus: (() -> Void)?

    @AppStorage(TerminalSettingsKeys.fontSize, store: SharedDefaults.store)
    private var preferredFontSize = TerminalSettings.fontSizeDefault

    var body: some View {
        if let launch = holder.ghosttyLaunch {
            GhosttyPane(
                holder: holder, launch: launch,
                theme: GhosttyTheme(
                    palette: palette,
                    fontSize: TerminalSettings.clampedFontSize(preferredFontSize)),
                active: active, wantsFocus: wantsFocus, onDropFiles: onDropFiles, onFocus: onFocus
            )
            .id(holder.generation)
        }
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
        view.onFocus = onFocus
        view.onDropFiles = onDropFiles
        view.setRenderingActive(active)
        return view
    }

    func updateNSView(_ view: GhosttyTerminalView, context: Context) {
        view.apply(theme: theme)
        view.onFocus = onFocus
        view.onDropFiles = onDropFiles
        view.setRenderingActive(active)
        if context.coordinator.shouldRequest(active: active, wantsFocus: wantsFocus) {
            view.requestFocus()
        } else if !(active && wantsFocus) {
            view.cancelFocusRequest()
        }
    }
}
