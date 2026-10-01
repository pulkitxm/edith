import AppKit
import GhosttyTerminal

enum TerminalZoomFocus {
    static func owns(_ responder: NSResponder?) -> Bool {
        responder is GhosttyTerminalView
    }
}
