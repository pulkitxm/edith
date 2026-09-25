import AppKit

@MainActor
final class NotchPanel: NSPanel {
    var acceptsKeyFocus = false
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { acceptsKeyFocus }

    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if acceptsKeyFocus, let keyEquivalentHandler, keyEquivalentHandler(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
