import AppKit
import ApplicationServices
import EdithKit
import Foundation

@MainActor
enum BifrostWindowManager {
    private static var restorePoints: [String: CGRect] = [:]

    static func perform(_ action: BifrostWindowAction) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let application = NSWorkspace.shared.frontmostApplication,
            let window = focusedWindow(pid: application.processIdentifier),
            let currentAX = frame(of: window),
            let screen = screen(containing: flipped(currentAX))
        else { return false }
        let visibleAX = flipped(screen.visibleFrame)
        let key = "\(application.processIdentifier):\(title(of: window) ?? "")"
        if action.restoresPrevious {
            guard let stored = restorePoints.removeValue(forKey: key) else { return false }
            return apply(stored, to: window)
        }
        guard let target = target(action, window: currentAX, visible: visibleAX, screen: screen)
        else { return false }
        restorePoints[key] = currentAX
        return apply(target, to: window)
    }

    static func focus(processID: pid_t, title: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return false }
        guard let match = windows.first(where: { self.title(of: $0) == title }) ?? windows.first
        else { return false }
        _ = NSRunningApplication(processIdentifier: processID)?.activate()
        AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(match, kAXRaiseAction as CFString)
        return true
    }

    private static func target(
        _ action: BifrostWindowAction, window: CGRect, visible: CGRect, screen: NSScreen
    ) -> CGRect? {
        guard action.movesDisplay else {
            return action.frame(in: visible, current: window)
        }
        guard let next = neighbour(of: screen, forward: action == .nextDisplay) else { return nil }
        return BifrostWindowAction.proportional(
            window, from: visible, to: flipped(next.visibleFrame))
    }

    private static func neighbour(of screen: NSScreen, forward: Bool) -> NSScreen? {
        let screens = NSScreen.screens
        guard screens.count > 1, let index = screens.firstIndex(of: screen) else { return nil }
        let offset = forward ? 1 : screens.count - 1
        return screens[(index + offset) % screens.count]
    }

    private static func screen(containing rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    static func flipped(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let window = value, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        let element = window as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    private static func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
                == .success
        else { return nil }
        return value as? String
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = point(window, attribute: kAXPositionAttribute),
            let size = size(window, attribute: kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func apply(_ frame: CGRect, to window: AXUIElement) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let originValue = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }
        let first = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, originValue)
        let second = AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, sizeValue)
        let third = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, originValue)
        return first == .success || second == .success || third == .success
    }

    private static func point(_ window: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = axValue(window, attribute: attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ window: AXUIElement, attribute: String) -> CGSize? {
        guard let value = axValue(window, attribute: attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(_ window: AXUIElement, attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success,
            let raw = value, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        return unsafeBitCast(raw, to: AXValue.self)
    }
}
