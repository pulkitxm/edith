import AppKit

enum HostWindowFramePolicy {
    @MainActor
    static func disableApplicationStateRestoration(_ window: NSWindow) {
        window.isRestorable = false
    }

    static func autosaveKey(name: String) -> String {
        "NSWindow Frame \(name)"
    }

    static func shouldDiscardAutosave(_ value: String?) -> Bool {
        value?.contains("tilingState") == true
    }

    static func minimumSize(visibleFrame: NSRect) -> NSSize {
        NSSize(
            width: min(960, visibleFrame.width),
            height: min(640, visibleFrame.height)
        )
    }

    static func defaultSize(visibleFrame: NSRect) -> NSSize {
        let minimum = minimumSize(visibleFrame: visibleFrame)
        return NSSize(
            width: min(
                visibleFrame.width,
                max(minimum.width, min(1240, visibleFrame.width * 0.82))
            ),
            height: min(
                visibleFrame.height,
                max(minimum.height, min(820, visibleFrame.height * 0.78)))
        )
    }

    static func fitted(_ size: NSSize, visible: NSSize) -> NSSize {
        NSSize(
            width: min(visible.width, size.width),
            height: min(visible.height, size.height))
    }

    static func normalizedFrame(_ frame: NSRect, visibleFrame: NSRect) -> NSRect {
        let minimum = minimumSize(visibleFrame: visibleFrame)
        let undersized = frame.width < minimum.width || frame.height < minimum.height
        let size =
            undersized
            ? defaultSize(visibleFrame: visibleFrame)
            : NSSize(
                width: min(visibleFrame.width, frame.width),
                height: min(visibleFrame.height, frame.height)
            )
        let resized = size != frame.size
        let origin =
            resized
            ? NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2)
            : NSPoint(
                x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width),
                y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height)
            )
        return NSRect(origin: origin, size: size)
    }
}
