import AppKit
import SwiftUI

struct SurfaceShelfWheelRouter: NSViewRepresentable {
    func makeNSView(context: Context) -> SurfaceShelfWheelView {
        let view = SurfaceShelfWheelView()
        view.start()
        return view
    }
    func updateNSView(_ nsView: SurfaceShelfWheelView, context: Context) {}
    static func dismantleNSView(_ nsView: SurfaceShelfWheelView, coordinator: ()) { nsView.stop() }
}

@MainActor final class SurfaceShelfWheelView: NSView {
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.route(event) ?? event }
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    private func route(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, !event.hasPreciseScrollingDeltas,
            event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
            let scroll = enclosingScrollView, let document = scroll.documentView,
            document.frame.width > scroll.contentView.bounds.width,
            bounds.contains(convert(event.locationInWindow, from: nil))
        else { return event }
        if let hit = window?.contentView?.hitTest(event.locationInWindow),
            let nested = hit.enclosingScrollView, nested !== scroll,
            let content = nested.documentView,
            content.frame.height > nested.contentView.bounds.height + 1
        {
            return event
        }
        let clip = scroll.contentView
        let x = min(
            max(0, clip.bounds.origin.x - event.scrollingDeltaY * 24),
            max(0, document.frame.width - clip.bounds.width))
        clip.scroll(to: CGPoint(x: x, y: clip.bounds.origin.y))
        scroll.reflectScrolledClipView(clip)
        return nil
    }
}
