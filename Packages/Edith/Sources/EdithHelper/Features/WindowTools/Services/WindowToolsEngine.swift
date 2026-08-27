import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import EdithKit

@MainActor
final class WindowToolsEngine: FeatureModule {
    private struct HotKeySpec {
        let id: UInt32
        let action: WindowLayoutAction
        let codeKey: String
        let modsKey: String
        let defaultCode: Int
    }

    private struct GreenTarget {
        let window: AXUIElement
        let origin: CGPoint
    }

    private var activationObserver: NSObjectProtocol?
    private var requestObserver: NSObjectProtocol?
    private var lastExternalApplication: NSRunningApplication?
    private var history: [UInt: [CGRect]] = [:]
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var greenTarget: GreenTarget?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard
                    let application = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                    !Self.isEdith(application)
                else { return }
                self?.lastExternalApplication = application
            }
        }
        requestObserver = IPC.observe(
            IPC.Name.requestWindowLayout,
            info: { [weak self] info in
                MainActor.assumeIsolated {
                    guard
                        let raw = info[WindowLayoutRequest.actionKey] as? String,
                        let action = WindowLayoutAction(rawValue: raw)
                    else { return }
                    self?.perform(action)
                }
            })
        if let frontmost = NSWorkspace.shared.frontmostApplication, !Self.isEdith(frontmost) {
            lastExternalApplication = frontmost
        }
        applySettings()
    }

    func applySettings() {
        registerHotKeys()
        let greenButtonOn =
            SharedDefaults.store.object(
                forKey: AppStorageKeys.WindowTools.greenButtonMaximizes) as? Bool ?? true
        if greenButtonOn, AXIsProcessTrusted() {
            startEventTap()
        } else {
            stopEventTap()
        }
    }

    func shutdown() {
        hotKeys.forEach { GlobalHotKey.clear(id: $0.id) }
        stopEventTap()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let requestObserver { IPC.stopObserving(requestObserver) }
        activationObserver = nil
        requestObserver = nil
        history.removeAll()
    }

    func perform(_ action: WindowLayoutAction) {
        guard AXIsProcessTrusted(), let window = focusedWindow() else { return }
        apply(action, to: window)
    }

    private var hotKeys: [HotKeySpec] {
        [
            HotKeySpec(
                id: GlobalHotKey.ID.windowLeft, action: .leftHalf,
                codeKey: AppStorageKeys.WindowTools.leftHotKeyCode,
                modsKey: AppStorageKeys.WindowTools.leftHotKeyMods, defaultCode: kVK_LeftArrow),
            HotKeySpec(
                id: GlobalHotKey.ID.windowRight, action: .rightHalf,
                codeKey: AppStorageKeys.WindowTools.rightHotKeyCode,
                modsKey: AppStorageKeys.WindowTools.rightHotKeyMods, defaultCode: kVK_RightArrow),
            HotKeySpec(
                id: GlobalHotKey.ID.windowMaximize, action: .maximize,
                codeKey: AppStorageKeys.WindowTools.maximizeHotKeyCode,
                modsKey: AppStorageKeys.WindowTools.maximizeHotKeyMods, defaultCode: kVK_ANSI_M),
            HotKeySpec(
                id: GlobalHotKey.ID.windowRestore, action: .restore,
                codeKey: AppStorageKeys.WindowTools.restoreHotKeyCode,
                modsKey: AppStorageKeys.WindowTools.restoreHotKeyMods, defaultCode: kVK_ANSI_R),
        ]
    }

    private func registerHotKeys() {
        for spec in hotKeys {
            let code =
                SharedDefaults.store.object(forKey: spec.codeKey) as? Int ?? spec.defaultCode
            let modifiers =
                SharedDefaults.store.object(forKey: spec.modsKey) as? Int
                ?? (controlKey | optionKey)
            GlobalHotKey.set(id: spec.id, keyCode: code, modifiers: modifiers) { [weak self] in
                MainActor.assumeIsolated { self?.perform(spec.action) }
            }
        }
    }

    private func focusedWindow() -> AXUIElement? {
        let running = NSWorkspace.shared.frontmostApplication
        let application = running.flatMap { Self.isEdith($0) ? nil : $0 } ?? lastExternalApplication
        guard let application, !application.isTerminated else { return nil }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return elementAttribute(element, kAXFocusedWindowAttribute as String)
    }

    private func apply(_ action: WindowLayoutAction, to window: AXUIElement) {
        guard let currentAX = frame(of: window) else { return }
        let current = appKitFrame(from: currentAX)
        let key = CFHash(window)
        if action == .restore {
            guard var frames = history[key], let previous = frames.popLast() else { return }
            if frames.isEmpty { history.removeValue(forKey: key) } else { history[key] = frames }
            _ = setFrame(axFrame(from: previous), on: window)
            return
        }
        guard let screen = bestScreen(for: current) else { return }
        let target: CGRect?
        if action == .nextDisplay {
            let screens = NSScreen.screens
            guard screens.count > 1, let index = screens.firstIndex(of: screen) else { return }
            let destination = screens[(index + 1) % screens.count].visibleFrame
            target = WindowLayoutGeometry.movedFrame(
                current: current, from: screen.visibleFrame, to: destination)
        } else {
            target = WindowLayoutGeometry.frame(
                for: action, current: current, visibleFrame: screen.visibleFrame)
        }
        guard let target, !close(current, target) else { return }
        if setFrame(axFrame(from: target), on: window) {
            var frames = history[key, default: []]
            if frames.last.map({ !close($0, current) }) ?? true { frames.append(current) }
            history[key] = Array(frames.suffix(8))
        }
    }

    private func toggleMaximize(_ window: AXUIElement) {
        guard let currentAX = frame(of: window) else { return }
        let current = appKitFrame(from: currentAX)
        let key = CFHash(window)
        if let screen = bestScreen(for: current), close(current, screen.visibleFrame),
            var frames = history[key], let previous = frames.popLast()
        {
            if frames.isEmpty { history.removeValue(forKey: key) } else { history[key] = frames }
            _ = setFrame(axFrame(from: previous), on: window)
            return
        }
        apply(.maximize, to: window)
    }

    private func startEventTap() {
        guard eventTap == nil else { return }
        let mask =
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, info in
                    guard let info else { return Unmanaged.passUnretained(event) }
                    let engine = Unmanaged<WindowToolsEngine>.fromOpaque(info).takeUnretainedValue()
                    return MainActor.assumeIsolated { engine.handleMouse(type, event) }
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let eventSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes)
        }
        eventTap = nil
        eventSource = nil
        greenTarget = nil
    }

    private func handleMouse(
        _ type: CGEventType, _ event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard AXIsProcessTrusted() else { return Unmanaged.passUnretained(event) }
        if type == .leftMouseDown {
            guard
                event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                    .isEmpty,
                let window = greenButtonWindow(at: event.location)
            else {
                greenTarget = nil
                return Unmanaged.passUnretained(event)
            }
            greenTarget = GreenTarget(window: window, origin: event.location)
            return nil
        }
        if type == .leftMouseUp, let target = greenTarget {
            greenTarget = nil
            let delta = hypot(
                event.location.x - target.origin.x, event.location.y - target.origin.y)
            if delta <= 8, CFEqual(target.window, greenButtonWindow(at: event.location)) {
                toggleMaximize(target.window)
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func greenButtonWindow(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.35)
        var hit: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
                == .success,
            let hit, let window = topLevelWindow(from: hit),
            let button = elementAttribute(window, kAXZoomButtonAttribute as String),
            boolAttribute(button, kAXEnabledAttribute as String, default: true),
            let buttonFrame = frame(of: button), buttonFrame.insetBy(dx: -3, dy: -3).contains(point)
        else { return nil }
        return window
    }

    private func topLevelWindow(from element: AXUIElement) -> AXUIElement? {
        if stringAttribute(element, kAXRoleAttribute as String) == kAXWindowRole as String {
            return element
        }
        if let window = elementAttribute(element, kAXWindowAttribute as String) { return window }
        var current = element
        for _ in 0..<8 {
            guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
                return nil
            }
            if stringAttribute(parent, kAXRoleAttribute as String) == kAXWindowRole as String {
                return parent
            }
            current = parent
        }
        return nil
    }

    private func bestScreen(for frame: CGRect) -> NSScreen? {
        NSScreen.screens.max {
            $0.frame.intersection(frame).area < $1.frame.intersection(frame).area
        }
    }

    private func axFrame(from frame: CGRect) -> CGRect {
        let top = desktopTop(fallback: frame.maxY)
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }

    private func appKitFrame(from frame: CGRect) -> CGRect {
        let top = desktopTop(fallback: frame.maxY)
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }

    private func desktopTop(fallback: CGFloat) -> CGFloat {
        let screens = NSScreen.screens
        guard let first = screens.first else { return fallback }
        var top = first.frame.maxY
        for screen in screens.dropFirst() {
            top = max(top, screen.frame.maxY)
        }
        return top
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = pointAttribute(element, kAXPositionAttribute as String),
            let size = sizeAttribute(element, kAXSizeAttribute as String), size.width > 0,
            size.height > 0
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func setFrame(_ frame: CGRect, on element: AXUIElement) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let originValue = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }
        let moved =
            AXUIElementSetAttributeValue(
                element, kAXPositionAttribute as CFString, originValue) == .success
        let resized =
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            == .success
        let settled =
            AXUIElementSetAttributeValue(
                element, kAXPositionAttribute as CFString, originValue) == .success
        return moved && resized && settled
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value
        else { return nil }
        return (value as! AXUIElement)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(
        _ element: AXUIElement, _ name: String, default fallback: Bool
    ) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return fallback
        }
        return (value as? NSNumber)?.boolValue ?? fallback
    }

    private func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func close(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 4 && abs(lhs.minY - rhs.minY) <= 4
            && abs(lhs.width - rhs.width) <= 4 && abs(lhs.height - rhs.height) <= 4
    }

    private static func isEdith(_ application: NSRunningApplication) -> Bool {
        application.bundleIdentifier?.hasPrefix("com.pulkit.edith") == true
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
