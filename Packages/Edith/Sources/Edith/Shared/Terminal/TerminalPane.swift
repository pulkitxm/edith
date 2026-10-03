import AppKit
import EdithKit
import GhosttyTerminal
import Observation
import SwiftTerm
import SwiftUI

struct TerminalPane: View {
    let holder: TerminalSessionHolder
    let palette: TerminalPalette
    var active = true
    var wantsFocus = true
    var fontSize: Double?
    var onDropFiles: ((TerminalDropPayload) -> Bool)?
    var onFocus: (() -> Void)?

    var body: some View {
        if GhosttyTerminals.enabled {
            if let launch = holder.ghosttyLaunch {
                GhosttyPane(
                    holder: holder, launch: launch,
                    theme: GhosttyTheme(palette: palette, fontSize: fontSize),
                    active: active, wantsFocus: wantsFocus, onDropFiles: onDropFiles,
                    onFocus: onFocus
                )
                .id(holder.generation)
            }
        } else {
            SwiftTermPane(
                holder: holder, palette: palette, active: active, wantsFocus: wantsFocus,
                scale: UIScale.current, onDropFiles: onDropFiles
            )
            .id(holder.generation)
        }
    }
}

struct SwiftTermPane: NSViewRepresentable {
    let holder: TerminalSessionHolder
    let palette: TerminalPalette
    var active = true
    var wantsFocus = true
    var scale = 1.0
    var onDropFiles: ((TerminalDropPayload) -> Bool)?

    func makeNSView(context: Context) -> EdithTerminalView {
        holder.applyTheme(palette, scale: scale)
        holder.updatePresentation(active: active, wantsFocus: wantsFocus)
        let view = holder.terminalView
        view.onDropFiles = onDropFiles
        view.registerForDraggedTypes(TerminalDropPayload.pasteboardTypes)
        return view
    }

    func updateNSView(_ view: EdithTerminalView, context: Context) {
        holder.applyTheme(palette, scale: scale)
        holder.updatePresentation(active: active, wantsFocus: wantsFocus)
        view.onDropFiles = onDropFiles
    }
}

