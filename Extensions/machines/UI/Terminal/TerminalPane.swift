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
    var hostPaneAction:
        ((GhosttyPaneAction, Double, MachineTerminalRequest, @escaping () -> Bool) -> Void)?

    @AppStorage(TerminalSettingsKeys.fontSize, store: SharedDefaults.store)
    private var preferredFontSize = TerminalSettings.fontSizeDefault

    var body: some View {
        if holder.hasTerminal {
            GhosttyPane(
                holder: holder,
                theme: GhosttyTheme(
                    palette: palette,
                    fontSize: TerminalSettings.clampedFontSize(preferredFontSize) * UIScale.current),
                active: active, wantsFocus: wantsFocus, onDropFiles: onDropFiles, onFocus: onFocus,
                hostPaneAction: hostPaneAction
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
    var onDropFiles: ((TerminalDropPayload) -> Bool)?
    var onFocus: (() -> Void)?
    var hostPaneAction:
        ((GhosttyPaneAction, Double, MachineTerminalRequest, @escaping () -> Bool) -> Void)?

    final class Coordinator {
        weak var holder: TerminalSessionHolder?
        private var requested = false

        func shouldRequest(active: Bool, wantsFocus: Bool) -> Bool {
            let next = active && wantsFocus
            defer { requested = next }
            return next && !requested
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GhosttyTerminalView {
        context.coordinator.holder = holder
        holder.hostPaneAction = hostPaneAction
        holder.presented = active
        let view = holder.retainedGhosttyView(theme: theme)
        view.onFocus = onFocus
        view.onDropFiles = onDropFiles
        view.setRenderingActive(active)
        return view
    }

    static func dismantleNSView(_ view: GhosttyTerminalView, coordinator: Coordinator) {
        coordinator.holder?.presented = false
        coordinator.holder?.hostPaneAction = nil
    }

    func updateNSView(_ view: GhosttyTerminalView, context: Context) {
        holder.hostPaneAction = hostPaneAction
        holder.presented = active
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
