import AppKit
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

    func makeNSView(context: Context) -> CanvasPointerView { CanvasPointerView() }

    func updateNSView(_ view: CanvasPointerView, context: Context) {
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

final class CanvasPointerView: NSView {
    var onChanged: ((CanvasPointerDrag) -> Void)?
    var onEnded: ((CanvasPointerDrag) -> Void)?
    private var origin: (local: CGPoint, screen: CGPoint)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
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
