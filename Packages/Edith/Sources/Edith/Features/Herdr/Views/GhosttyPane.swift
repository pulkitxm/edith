import GhosttyTerminal
import SwiftUI

struct GhosttyPane: NSViewRepresentable {
    let launch: GhosttyLaunch
    var onClose: (() -> Void)?

    func makeNSView(context: Context) -> GhosttyTerminalView {
        let view = GhosttyTerminalView(launch: launch)
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: GhosttyTerminalView, context: Context) {
        view.onClose = onClose
    }
}
