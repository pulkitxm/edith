import AppKit

public enum ClipboardPopupPosition: String, CaseIterable, Identifiable, Sendable {
    case cursor
    case statusItem
    case window
    case center
    case lastPosition

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cursor: "Cursor"
        case .statusItem: "Menu icon"
        case .window: "Window center"
        case .center: "Screen center"
        case .lastPosition: "Last position"
        }
    }

    public static var current: ClipboardPopupPosition {
        ClipboardPopupPosition(
            rawValue: SharedDefaults.store.string(forKey: "clipboardPopupAt") ?? "") ?? .cursor
    }

    @MainActor
    public func origin(size: NSSize, statusItemFrame: NSRect?) -> NSPoint {
        switch self {
        case .cursor:
            var point = NSEvent.mouseLocation
            point.y -= size.height
            return point
        case .statusItem:
            guard let statusItemFrame, let screen = Self.popupScreen() else {
                return Self.centered(size)
            }
            var point = NSPoint(
                x: statusItemFrame.minX, y: statusItemFrame.minY - size.height)
            if point.x + size.width > screen.frame.maxX {
                point.x = screen.frame.maxX - size.width
            }
            return point
        case .window:
            guard let frame = Self.frontmostWindowFrame() else { return Self.centered(size) }
            return NSPoint(
                x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        case .center:
            return Self.centered(size)
        case .lastPosition:
            guard let screen = Self.popupScreen() else { return .zero }
            let store = SharedDefaults.store
            let relX = store.object(forKey: "clipboardWindowPositionX") as? Double ?? 0.5
            let relY = store.object(forKey: "clipboardWindowPositionY") as? Double ?? 0.8
            let frame = screen.frame
            return NSPoint(
                x: frame.minX + frame.width * relX - size.width / 2,
                y: frame.minY + frame.height * relY - size.height)
        }
    }

    @MainActor
    public static func saveLastPosition(frame: NSRect, screen: NSScreen?) {
        guard let screen else { return }
        let bounds = screen.frame
        guard bounds.width > 0, bounds.height > 0 else { return }
        let store = SharedDefaults.store
        store.set(
            Double((frame.midX - bounds.minX) / bounds.width),
            forKey: "clipboardWindowPositionX")
        store.set(
            Double((frame.maxY - bounds.minY) / bounds.height),
            forKey: "clipboardWindowPositionY")
    }

    @MainActor
    private static func popupScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    @MainActor
    private static func centered(_ size: NSSize) -> NSPoint {
        guard let visible = popupScreen()?.visibleFrame else { return .zero }
        return NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    }

    @MainActor
    private static func frontmostWindowFrame() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                pid == app.processIdentifier,
                info[kCGWindowLayer as String] as? Int == 0,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                let width = bounds["Width"], let height = bounds["Height"],
                width > 1, height > 1
            else { continue }
            return NSRect(
                x: bounds["X"] ?? 0,
                y: primaryHeight - (bounds["Y"] ?? 0) - height,
                width: width, height: height)
        }
        return nil
    }
}
