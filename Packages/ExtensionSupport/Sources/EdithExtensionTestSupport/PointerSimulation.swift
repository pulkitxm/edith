import AppKit

public final class PointerTestWindow: NSWindow {
    public var pointer = NSPoint(x: -10_000, y: -10_000)
    var insideAreas = Set<ObjectIdentifier>()

    public override var canBecomeKey: Bool { true }
    public override var isKeyWindow: Bool { true }
    public override var mouseLocationOutsideOfEventStream: NSPoint { pointer }

    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
public enum PointerSimulation {
    public static func window(contentRect: NSRect) -> PointerTestWindow {
        _ = TestWindowHost.application
        let window = PointerTestWindow(
            contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        window.setFrameOrigin(
            NSPoint(x: minX - contentRect.width - 1_000, y: minY - contentRect.height - 1_000))
        return window
    }

    public static func move(
        to point: NSPoint, in window: PointerTestWindow, crossings: Bool = true
    ) {
        window.pointer = point
        guard let root = window.contentView else { return }
        let time = ProcessInfo.processInfo.systemUptime
        var pending: [NSView] = [root]
        var visited: [(view: NSView, area: NSTrackingArea)] = []
        while let view = pending.popLast() {
            pending += view.subviews
            for area in view.trackingAreas { visited.append((view, area)) }
        }
        var entered = Set<ObjectIdentifier>()
        for (view, area) in visited {
            let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
            let inside =
                !view.isHiddenOrHasHiddenAncestor && rect.contains(view.convert(point, from: nil))
            let key = ObjectIdentifier(area)
            let wasInside = window.insideAreas.contains(key)
            if inside { entered.insert(key) }
            guard let owner = area.owner as? NSResponder else { continue }
            if crossings, inside != wasInside, area.options.contains(.mouseEnteredAndExited),
                let crossing = NSEvent.enterExitEvent(
                    with: inside ? .mouseEntered : .mouseExited, location: point,
                    modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0,
                    trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil)
            {
                if inside {
                    owner.mouseEntered(with: crossing)
                } else {
                    owner.mouseExited(with: crossing)
                }
            }
            if inside, area.options.contains(.mouseMoved),
                let moved = NSEvent.mouseEvent(
                    with: .mouseMoved, location: point, modifierFlags: [], timestamp: time,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
                    pressure: 0)
            {
                owner.mouseMoved(with: moved)
            }
        }
        window.insideAreas = entered
    }

    public static func move(
        to point: CGPoint, in view: NSView, window: PointerTestWindow, crossings: Bool = true
    ) {
        move(to: view.convert(point, to: nil), in: window, crossings: crossings)
    }

    public static func leave(_ window: PointerTestWindow) {
        move(to: NSPoint(x: -10_000, y: -10_000), in: window)
    }
}
