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

    @AppStorage(AppStorageKeys.Herdr.terminalFontSize, store: SharedDefaults.store)
    private var preferredFontSize = HerdrTerminalSettings.fontSizeDefault

    private var resolvedFontSize: Double {
        HerdrTerminalSettings.clampedFontSize(fontSize ?? preferredFontSize)
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
