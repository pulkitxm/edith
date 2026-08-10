import AppKit

@MainActor
public enum ScrollForwarding {
    private static var monitor: Any?

    private static var gestureTarget: NSScrollView?

    public static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window,
                let hit = window.contentView?.hitTest(event.locationInWindow),
                hit.enclosingScrollView == nil
            else {
                gestureTarget = nil
                return event
            }
            guard let target = target(for: event, in: hit) else { return event }
            target.scrollWheel(with: event)
            return nil
        }
    }

    public static func startsGesture(phase: NSEvent.Phase, momentum: NSEvent.Phase) -> Bool {
        phase.contains(.began) || phase.contains(.mayBegin) || momentum.contains(.began)
            || (phase.isEmpty && momentum.isEmpty)
    }

    public static func carriesVerticalScroll(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        abs(deltaY) >= abs(deltaX)
    }

    public static func scrollsVertically(content: CGFloat, visible: CGFloat) -> Bool {
        content - visible > 1
    }

    private static func target(for event: NSEvent, in hit: NSView) -> NSScrollView? {
        if startsGesture(phase: event.phase, momentum: event.momentumPhase) {
            guard
                carriesVerticalScroll(
                    deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            else {
                gestureTarget = nil
                return nil
            }
            gestureTarget = nearestScrollView(from: hit)
        }
        guard let target = gestureTarget, target.window != nil else { return nil }
        return target
    }

    private static func nearestScrollView(from view: NSView) -> NSScrollView? {
        var branch: NSView? = view
        var visited: NSView?
        while let current = branch {
            if let found = widestScrollView(in: current, skipping: visited) { return found }
            visited = current
            branch = current.superview
        }
        return nil
    }

    private static func widestScrollView(in view: NSView, skipping: NSView?) -> NSScrollView? {
        var best: NSScrollView?
        for subview in view.subviews where subview !== skipping && !subview.isHidden {
            let candidate: NSScrollView?
            if let scroll = subview as? NSScrollView, scrollable(scroll) {
                candidate = scroll
            } else {
                candidate = widestScrollView(in: subview, skipping: skipping)
            }
            guard let candidate else { continue }
            if best.map({ candidate.bounds.width > $0.bounds.width }) ?? true {
                best = candidate
            }
        }
        return best
    }

    private static func scrollable(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return false }
        return scrollsVertically(
            content: document.frame.height, visible: scroll.contentView.bounds.height)
    }
}
