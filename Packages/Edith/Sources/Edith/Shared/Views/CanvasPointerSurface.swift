import AppKit
import EdithKit
import SwiftUI

struct CanvasPointerDrag {
    let startLocation: CGPoint
    let translation: CGSize
    let modifierFlags: NSEvent.ModifierFlags

    var location: CGPoint {
        CGPoint(x: startLocation.x + translation.width, y: startLocation.y + translation.height)
    }
}

struct CanvasPointerSurface: NSViewRepresentable {
    let onChanged: (CanvasPointerDrag) -> Void
    let onEnded: (CanvasPointerDrag) -> Void
    var onKeyDown: ((NSEvent) -> Bool)? = nil

    func makeNSView(context: Context) -> CanvasPointerView { CanvasPointerView() }

    func updateNSView(_ view: CanvasPointerView, context: Context) {
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onKeyDown = onKeyDown
    }
}

final class CanvasPointerView: NSView, DirectKeyboardInputResponder {
    var onChanged: ((CanvasPointerDrag) -> Void)?
    var onEnded: ((CanvasPointerDrag) -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?
    private var origin: (local: CGPoint, screen: CGPoint)?
    override var acceptsFirstResponder: Bool { onKeyDown != nil }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if acceptsFirstResponder { window.makeFirstResponder(self) }
        origin = (
            convert(event.locationInWindow, from: nil),
            window.convertPoint(toScreen: event.locationInWindow)
        )
        if let drag = drag(event) { onChanged?(drag) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let drag = drag(event) { onChanged?(drag) }
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = drag(event) { onEnded?(drag) }
        origin = nil
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        return onKeyDown?(event) == true || super.performKeyEquivalent(with: event)
    }

    private func drag(_ event: NSEvent) -> CanvasPointerDrag? {
        guard let origin, let window else { return nil }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        return CanvasPointerDrag(
            startLocation: origin.local,
            translation: CGSize(
                width: point.x - origin.screen.x, height: origin.screen.y - point.y),
            modifierFlags: event.modifierFlags)
    }
}
