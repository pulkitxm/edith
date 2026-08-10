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
        Self.clampedToScreen(unclampedOrigin(size: size, statusItemFrame: statusItemFrame), size)
    }

    @MainActor
    private func unclampedOrigin(size: NSSize, statusItemFrame: NSRect?) -> NSPoint {
        switch self {
        case .cursor:
            if let caret = Self.focusedTextRect() {
                return NSPoint(x: caret.minX, y: caret.minY - size.height - 4)
            }
            var point = NSEvent.mouseLocation
            point.y -= size.height
            return point
        case .statusItem:
            guard let statusItemFrame else { return Self.centered(size) }
            return NSPoint(x: statusItemFrame.minX, y: statusItemFrame.minY - size.height)
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
    public static func clampedToScreen(_ point: NSPoint, _ size: NSSize) -> NSPoint {
        let screen =
            NSScreen.screens.first {
                $0.frame.contains(NSPoint(x: point.x, y: point.y + size.height))
            } ?? popupScreen()
        guard let visible = screen?.visibleFrame else { return point }
        return NSPoint(
            x: min(max(point.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(point.y, visible.minY), max(visible.minY, visible.maxY - size.height)))
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
    private static func focusedTextRect() -> NSRect? {
        guard AXIsProcessTrusted(), let element = focusedElement() else { return nil }
        if let caret = caretRect(of: element) { return caret }
        return textElementRect(of: element)
    }

    @MainActor
    private static func focusedElement() -> AXUIElement? {
        var candidates = [AXUIElementCreateSystemWide()]
        if let app = NSWorkspace.shared.frontmostApplication {
            candidates.append(AXUIElementCreateApplication(app.processIdentifier))
        }
        for candidate in candidates {
            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                candidate, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
            {
                return unsafeBitCast(focusedRef, to: AXUIElement.self)
            }
        }
        return nil
    }

    private static func caretRect(of element: AXUIElement) -> NSRect? {
        var rangeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
            let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        let selected = unsafeBitCast(rangeRef, to: AXValue.self)
        var range = CFRange()
        AXValueGetValue(selected, .cfRange, &range)
        var probes = [selected]
        if range.length == 0 {
            for location in [range.location, max(range.location - 1, 0)] {
                var widened = CFRange(location: location, length: 1)
                if let value = AXValueCreate(.cfRange, &widened) { probes.append(value) }
            }
        }
        for probe in probes {
            var boundsRef: CFTypeRef?
            guard
                AXUIElementCopyParameterizedAttributeValue(
                    element, kAXBoundsForRangeParameterizedAttribute as CFString, probe,
                    &boundsRef) == .success,
                let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID()
            else { continue }
            var rect = CGRect.zero
            guard AXValueGetValue(unsafeBitCast(boundsRef, to: AXValue.self), .cgRect, &rect),
                rect.height > 0, rect.height < 300, rect.origin != .zero
            else { continue }
            return flippedToCocoa(rect)
        }
        return nil
    }

    private static func textElementRect(of element: AXUIElement) -> NSRect? {
        var roleRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
                == .success,
            let role = roleRef as? String,
            ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role)
        else { return nil }
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &positionRef) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
                == .success,
            let positionRef, CFGetTypeID(positionRef) == AXValueGetTypeID(),
            let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(unsafeBitCast(positionRef, to: AXValue.self), .cgPoint, &position),
            AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size),
            size.height > 0
        else { return nil }
        return flippedToCocoa(CGRect(origin: position, size: size))
    }

    private static func flippedToCocoa(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(
            x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
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
        guard CGPreflightScreenCaptureAccess(),
            let app = NSWorkspace.shared.frontmostApplication,
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
