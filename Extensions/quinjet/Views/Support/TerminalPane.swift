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
    var onFocus: (() -> Void)?

    @AppStorage("quinjetTerminalFontSize", store: SharedDefaults.store)
    private var preferredFontSize = 13.0

    private var resolvedFontSize: Double {
        min(72, max(6, fontSize ?? preferredFontSize))
    }

    var body: some View {
        if holder.descriptor != nil {
            GhosttyPane(
                holder: holder,
                theme: GhosttyTheme(palette: palette, fontSize: resolvedFontSize),
                active: active, wantsFocus: wantsFocus,
                onFocus: onFocus
            )
            .id(holder.generation)
        }
    }
}
