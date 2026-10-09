import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import GhosttyTerminal
import Observation
import SwiftUI

struct TerminalPane: View {
    let holder: TerminalSessionHolder
    let palette: TerminalPalette
    var active = true
    var wantsFocus = true
    var fontSize: Double?
    var onDropFiles: ((TerminalDropPayload) -> Bool)?
    var onFocus: (() -> Void)?

    @AppStorage("quinjetTerminalFontSize", store: SharedDefaults.store)
    private var preferredFontSize = 13.0

    private var resolvedFontSize: Double {
        min(72, max(6, fontSize ?? preferredFontSize))
    }

    var body: some View {
        if let launch = holder.ghosttyLaunch {
            GhosttyPane(
                holder: holder, launch: launch,
                theme: GhosttyTheme(palette: palette, fontSize: resolvedFontSize),
                active: active, wantsFocus: wantsFocus, onDropFiles: onDropFiles,
                onFocus: onFocus
            )
            .id(holder.generation)
        }
    }
}
