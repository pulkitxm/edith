import AppKit

@MainActor
enum TestWindowHost {
    static let application: NSApplication = {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        return application
    }()

    static func window(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask = [.borderless]
    ) -> OffscreenTestWindow {
        _ = application
        let window = OffscreenTestWindow(
            contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.setFrameOrigin(offscreenOrigin(for: contentRect.size))
        return window
    }

    static func isExposedOnDesktop(_ window: NSWindow) -> Bool {
        window.isVisible && NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    static var exposedWindows: [NSWindow] {
        NSApp?.windows.filter(isExposedOnDesktop) ?? []
    }

    private static func offscreenOrigin(for size: NSSize) -> NSPoint {
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        return NSPoint(x: minX - size.width - 1_000, y: minY - size.height - 1_000)
    }
}

final class OffscreenTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
