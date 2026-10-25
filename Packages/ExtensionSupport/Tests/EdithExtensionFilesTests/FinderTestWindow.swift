import AppKit

@MainActor
enum FinderTestWindow {
    static func make(contentRect: NSRect) -> OffscreenFinderTestWindow {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = OffscreenFinderTestWindow(
            contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        window.setFrameOrigin(
            NSPoint(
                x: minX - contentRect.size.width - 1_000, y: minY - contentRect.size.height - 1_000)
        )
        return window
    }
}

final class OffscreenFinderTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
