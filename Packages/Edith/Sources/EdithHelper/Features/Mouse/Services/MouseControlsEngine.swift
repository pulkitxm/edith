import AppKit
import ApplicationServices
import CoreGraphics
import EdithKit
import Foundation

@MainActor
final class MouseControlsEngine {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var frameTimer: Timer?
    private var pendingFocus: DispatchWorkItem?
    private var remainingVertical = 0.0
    private var remainingHorizontal = 0.0
    private var currentFlags: CGEventFlags = []
    private var pressedButtons: Set<Int> = []
    private var claimedButtons: Set<Int> = []
    private var untouchedButtons: Set<Int> = []
    private var smoothScroll = true
    private var scrollStep = MouseControlSupport.defaultScrollStep
    private var reverseVertical = false
    private var reverseHorizontal = false
    private var focusFollowsPointer = false
    private var focusDelay = MouseControlSupport.defaultFocusDelay
    private var sideNavigation = true
    private var actions: [Int: String] = [:]
    private var exclusions: Set<String> = []
    private let windowResolver = MouseWindowResolver()

    init() {
        syncSettings()
    }

    var isRunning: Bool { tap != nil }

    func syncSettings() {
        let defaults = SharedDefaults.store
        smoothScroll = Self.bool(defaults, AppStorageKeys.Mouse.smoothScroll, fallback: true)
        scrollStep = MouseControlSupport.sanitizedScrollStep(
            defaults.integer(forKey: AppStorageKeys.Mouse.scrollStep))
        reverseVertical = defaults.bool(forKey: AppStorageKeys.Mouse.reverseVertical)
        reverseHorizontal = defaults.bool(forKey: AppStorageKeys.Mouse.reverseHorizontal)
        focusFollowsPointer = defaults.bool(forKey: AppStorageKeys.Mouse.focusFollowsPointer)
        focusDelay = MouseControlSupport.sanitizedFocusDelay(
            defaults.integer(forKey: AppStorageKeys.Mouse.focusDelay))
        sideNavigation = Self.bool(
            defaults, AppStorageKeys.Mouse.sideNavigation, fallback: true)
        actions = Dictionary(
            uniqueKeysWithValues: zip(
                MouseControlSupport.buttonNumbers,
                [
                    AppStorageKeys.Mouse.button4Action, AppStorageKeys.Mouse.button5Action,
                    AppStorageKeys.Mouse.button6Action, AppStorageKeys.Mouse.button7Action,
                    AppStorageKeys.Mouse.button8Action,
                ].map { defaults.string(forKey: $0) ?? "" }))
        exclusions = MouseControlSupport.excludedBundleIDs(
            defaults.string(forKey: AppStorageKeys.Mouse.excludedApps))
        windowResolver.invalidate()
        if AXIsProcessTrusted() {
            start()
        } else {
            stop()
        }
        if !focusFollowsPointer { cancelFocus() }
        if !smoothScroll { stopGlide() }
    }

    func shutdown() {
        stop()
    }

    private func start() {
        guard tap == nil else { return }
        let mask = Self.mask([
            .scrollWheel, .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown,
            .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged,
            .rightMouseDragged, .otherMouseDragged,
        ])
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, pointer in
                    guard let pointer else { return Unmanaged.passUnretained(event) }
                    let engine = Unmanaged<MouseControlsEngine>.fromOpaque(pointer)
                        .takeUnretainedValue()
                    return MainActor.assumeIsolated {
                        engine.handle(type: type, event: event)
                    }
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        cancelFocus()
        stopGlide()
        pressedButtons.removeAll()
        claimedButtons.removeAll()
        untouchedButtons.removeAll()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData)
            == MouseControlSupport.syntheticEventTag
        {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .scrollWheel:
            return handleScroll(event)
        case .mouseMoved:
            handlePointerMove(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return handleButtonDown(event)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return handleButtonUp(event)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            cancelFocus()
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
            event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0,
            !event.flags.contains(.maskControl), !isExcluded(at: event.location)
        else { return Unmanaged.passUnretained(event) }
        if !smoothScroll {
            invert(event, axis: .scrollWheelEventDeltaAxis1, factor: reverseVertical ? -1 : 1)
            invert(
                event, axis: .scrollWheelEventDeltaAxis2,
                factor: reverseHorizontal ? -1 : 1)
            return Unmanaged.passUnretained(event)
        }
        let vertical = MouseControlSupport.ticks(
            integer: Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
            fixedPoint: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        let horizontal = MouseControlSupport.ticks(
            integer: Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
            fixedPoint: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        let shifted = event.flags.contains(.maskShift) && horizontal == 0
        let axes = MouseControlSupport.axes(
            vertical: vertical, horizontal: horizontal, shiftPressed: shifted,
            reverseVertical: reverseVertical, reverseHorizontal: reverseHorizontal)
        guard axes.vertical != 0 || axes.horizontal != 0 else {
            return Unmanaged.passUnretained(event)
        }
        remainingVertical = MouseControlSupport.nextRemaining(
            current: remainingVertical, added: axes.vertical * Double(scrollStep))
        remainingHorizontal = MouseControlSupport.nextRemaining(
            current: remainingHorizontal, added: axes.horizontal * Double(scrollStep))
        currentFlags = shifted ? event.flags.subtracting(.maskShift) : event.flags
        startGlide()
        return nil
    }

    private func invert(_ event: CGEvent, axis: CGEventField, factor: Int64) {
        guard factor == -1 else { return }
        event.setIntegerValueField(axis, value: -event.getIntegerValueField(axis))
        let fixedAxis: CGEventField =
            axis == .scrollWheelEventDeltaAxis1
            ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
        let pointAxis: CGEventField =
            axis == .scrollWheelEventDeltaAxis1
            ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        event.setDoubleValueField(fixedAxis, value: -event.getDoubleValueField(fixedAxis))
        event.setIntegerValueField(pointAxis, value: -event.getIntegerValueField(pointAxis))
    }

    private func startGlide() {
        guard frameTimer == nil else { return }
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.emitFrame() }
        }
        if let frameTimer { RunLoop.main.add(frameTimer, forMode: .common) }
    }

    private func emitFrame() {
        let vertical = consume(&remainingVertical)
        let horizontal = consume(&remainingHorizontal)
        guard vertical != 0 || horizontal != 0 else {
            stopGlide()
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: vertical, wheel2: horizontal, wheel3: 0)
        else { return }
        event.flags = currentFlags
        event.setIntegerValueField(
            .eventSourceUserData, value: MouseControlSupport.syntheticEventTag)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
        if remainingVertical == 0, remainingHorizontal == 0 { stopGlide() }
    }

    private func consume(_ remaining: inout Double) -> Int32 {
        guard remaining != 0 else { return 0 }
        if abs(remaining) <= 1 {
            let result: Int32 = remaining < 0 ? -1 : 1
            remaining = 0
            return result
        }
        let delta = MouseControlSupport.frameDelta(remaining)
        let pixels = Int32(delta.rounded(.toNearestOrAwayFromZero))
        remaining -= Double(pixels)
        return pixels
    }

    private func stopGlide() {
        frameTimer?.invalidate()
        frameTimer = nil
        remainingVertical = 0
        remainingHorizontal = 0
    }

    private func handlePointerMove(_ event: CGEvent) {
        guard focusFollowsPointer, pressedButtons.isEmpty,
            !Self.hasBlockingModifiers(event.flags), !isExcluded(at: event.location)
        else {
            cancelFocus()
            return
        }
        cancelFocus()
        let point = event.location
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.focus(at: point) }
        }
        pendingFocus = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(focusDelay) / 1_000, execute: work)
    }

    private func focus(at point: CGPoint) {
        pendingFocus = nil
        guard focusFollowsPointer, pressedButtons.isEmpty,
            !Self.hasBlockingModifiers(CGEventSource.flagsState(.combinedSessionState)),
            let app = windowResolver.application(at: point), !isExcluded(app)
        else { return }
        guard !app.isActive else { return }
        app.activate(options: [.activateAllWindows])
    }

    private func cancelFocus() {
        pendingFocus?.cancel()
        pendingFocus = nil
    }

    private func handleButtonDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        pressedButtons.insert(button)
        cancelFocus()
        guard MouseControlSupport.buttonNumbers.contains(button) else {
            return Unmanaged.passUnretained(event)
        }
        guard !isExcluded(at: event.location) else {
            untouchedButtons.insert(button)
            return Unmanaged.passUnretained(event)
        }
        let action = MouseControlSupport.resolvedAction(
            buttonNumber: button, stored: actions[button], sideNavigation: sideNavigation)
        guard action != .passThrough else { return Unmanaged.passUnretained(event) }
        claimedButtons.insert(button)
        perform(action, at: event.location)
        return nil
    }

    private func handleButtonUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        pressedButtons.remove(button)
        if untouchedButtons.remove(button) != nil { return Unmanaged.passUnretained(event) }
        if claimedButtons.remove(button) != nil { return nil }
        return Unmanaged.passUnretained(event)
    }

    private func perform(_ action: MouseButtonAction, at point: CGPoint) {
        switch action {
        case .automatic, .passThrough:
            break
        case .back:
            postKey(33, flags: .maskCommand)
        case .forward:
            postKey(30, flags: .maskCommand)
        case .middleClick:
            postMiddleClick(at: point)
        case .closeTab:
            postKey(13, flags: .maskCommand)
        case .reopenTab:
            postKey(17, flags: [.maskCommand, .maskShift])
        case .missionControl:
            postKey(126, flags: .maskControl)
        case .appExpose:
            postKey(125, flags: .maskControl)
        case .showDesktop:
            postKey(103, flags: [])
        }
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(
                .eventSourceUserData, value: MouseControlSupport.syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    private func postMiddleClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(
                mouseEventSource: source, mouseType: .otherMouseDown,
                mouseCursorPosition: point, mouseButton: .center),
            let up = CGEvent(
                mouseEventSource: source, mouseType: .otherMouseUp,
                mouseCursorPosition: point, mouseButton: .center)
        else { return }
        for event in [down, up] {
            event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            event.setIntegerValueField(
                .eventSourceUserData, value: MouseControlSupport.syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    private func isExcluded(at point: CGPoint) -> Bool {
        isExcluded(windowResolver.application(at: point))
    }

    private func isExcluded(_ app: NSRunningApplication?) -> Bool {
        MouseControlSupport.isExcluded(app?.bundleIdentifier, from: exclusions)
    }

    private static func bool(_ defaults: UserDefaults, _ key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private static func hasBlockingModifiers(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty
    }

    private static func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
    }
}

@MainActor
private final class MouseWindowResolver {
    private var cachedFrame: CGRect?
    private var cachedProcessID: pid_t?
    private var cachedAt = -Double.infinity
    private static let ownProcessID = getpid()

    func application(at point: CGPoint) -> NSRunningApplication? {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedFrame, cachedFrame.contains(point), now - cachedAt < 0.5,
            let cachedProcessID
        {
            return NSRunningApplication(processIdentifier: cachedProcessID)
        }
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return NSWorkspace.shared.frontmostApplication }
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                pid != Self.ownProcessID,
                let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                (0...3).contains(layer),
                (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let x = (bounds["X"] as? NSNumber)?.doubleValue,
                let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                let height = (bounds["Height"] as? NSNumber)?.doubleValue
            else { continue }
            let frame = CGRect(x: x, y: y, width: width, height: height)
            guard frame.contains(point) else { continue }
            cachedFrame = frame
            cachedProcessID = pid
            cachedAt = now
            return NSRunningApplication(processIdentifier: pid)
        }
        cachedFrame = nil
        cachedProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        cachedAt = now
        return NSWorkspace.shared.frontmostApplication
    }

    func invalidate() {
        cachedFrame = nil
        cachedProcessID = nil
        cachedAt = -Double.infinity
    }
}
