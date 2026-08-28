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
    private var focusGeneration: UInt64 = 0
    private var remainingVertical = 0.0
    private var remainingHorizontal = 0.0
    private var carryVertical = 0.0
    private var carryHorizontal = 0.0
    private var currentFlags: CGEventFlags = []
    private var glideFromContinuous = false
    private var lastGesturePhaseTimestamp: UInt64?
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
    private var middleClick = false
    private var middleClickSourceButton: Int?
    private var suppressedMiddleClickSourceButton: Int?
    private var lastMiddleClickEnd: TimeInterval?
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
        middleClick = defaults.bool(forKey: AppStorageKeys.Mouse.middleClick)
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
            if middleClick {
                TrackpadContactMonitor.shared.start()
            } else {
                releaseHeldMiddleButton()
                suppressedMiddleClickSourceButton = nil
                TrackpadContactMonitor.shared.stop()
            }
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
        releaseHeldMiddleButton()
        TrackpadContactMonitor.shared.stop()
        pressedButtons.removeAll()
        claimedButtons.removeAll()
        untouchedButtons.removeAll()
        suppressedMiddleClickSourceButton = nil
        lastMiddleClickEnd = nil
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
            releaseHeldMiddleButton()
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
            return handleButtonDrag(event)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let traits = MouseControlSupport.ScrollTraits(
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            scrollCount: event.getIntegerValueField(.scrollWheelEventScrollCount))
        let timestamp = UInt64(event.timestamp)
        let secondsSinceGesture = lastGesturePhaseTimestamp.map {
            Double(timestamp &- $0) / 1_000_000_000
        }
        if traits.momentumPhase != 0 || traits.scrollPhase != 0 {
            lastGesturePhaseTimestamp = timestamp
        }
        guard
            MouseControlSupport.isMouseWheel(
                traits, secondsSinceLastGesturePhase: secondsSinceGesture),
            !event.flags.contains(.maskControl), !isExcluded(at: event.location)
        else { return Unmanaged.passUnretained(event) }
        if !smoothScroll {
            invert(event, axis: .scrollWheelEventDeltaAxis1, factor: reverseVertical ? -1 : 1)
            invert(
                event, axis: .scrollWheelEventDeltaAxis2,
                factor: reverseHorizontal ? -1 : 1)
            return Unmanaged.passUnretained(event)
        }
        let shifted: Bool
        let axes: (vertical: Double, horizontal: Double)
        let step: Double
        if traits.isContinuous {
            shifted = false
            axes = (
                MouseControlSupport.continuousDistance(
                    fixedPoint: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                    point: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
                    step: Double(scrollStep)) * (reverseVertical ? -1.0 : 1.0),
                MouseControlSupport.continuousDistance(
                    fixedPoint: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                    point: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
                    step: Double(scrollStep)) * (reverseHorizontal ? -1.0 : 1.0)
            )
            step = 1
        } else {
            let vertical = MouseControlSupport.ticks(
                integer: Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
                fixedPoint: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
            let horizontal = MouseControlSupport.ticks(
                integer: Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                fixedPoint: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
            shifted = event.flags.contains(.maskShift) && horizontal == 0
            axes = MouseControlSupport.axes(
                vertical: vertical, horizontal: horizontal, shiftPressed: shifted,
                reverseVertical: reverseVertical, reverseHorizontal: reverseHorizontal)
            step = Double(scrollStep)
        }
        guard axes.vertical != 0 || axes.horizontal != 0 else {
            return Unmanaged.passUnretained(event)
        }
        if glideFromContinuous != traits.isContinuous
            || currentFlags.contains(.maskShift) != event.flags.contains(.maskShift)
        {
            remainingVertical = 0
            remainingHorizontal = 0
            carryVertical = 0
            carryHorizontal = 0
        }
        carryVertical = MouseControlSupport.continuingCarry(
            carryVertical, distance: axes.vertical)
        carryHorizontal = MouseControlSupport.continuingCarry(
            carryHorizontal, distance: axes.horizontal)
        remainingVertical = MouseControlSupport.nextRemaining(
            current: remainingVertical, added: axes.vertical * step)
        remainingHorizontal = MouseControlSupport.nextRemaining(
            current: remainingHorizontal, added: axes.horizontal * step)
        currentFlags = shifted ? event.flags.subtracting(.maskShift) : event.flags
        glideFromContinuous = traits.isContinuous
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
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.emitFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
        emitFrame()
    }

    private func emitFrame() {
        let vertical = MouseControlSupport.frameDelta(remainingVertical)
        let horizontal = MouseControlSupport.frameDelta(remainingHorizontal)
        remainingVertical -= vertical
        remainingHorizontal -= horizontal
        let landing = remainingVertical == 0 && remainingHorizontal == 0
        let verticalFrame =
            landing
            ? (
                pixels: MouseControlSupport.finalPixels(vertical, carry: carryVertical),
                carry: 0.0
            )
            : MouseControlSupport.wholePixels(vertical, carry: carryVertical)
        let horizontalFrame =
            landing
            ? (
                pixels: MouseControlSupport.finalPixels(horizontal, carry: carryHorizontal),
                carry: 0.0
            )
            : MouseControlSupport.wholePixels(horizontal, carry: carryHorizontal)
        carryVertical = verticalFrame.carry
        carryHorizontal = horizontalFrame.carry
        let verticalPixels = Self.pixelField(verticalFrame.pixels)
        let horizontalPixels = Self.pixelField(horizontalFrame.pixels)
        if verticalPixels == 0, horizontalPixels == 0 {
            if landing { finishGlide() }
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: verticalPixels, wheel2: horizontalPixels, wheel3: 0)
        else { return }
        event.flags = currentFlags
        event.setIntegerValueField(
            .eventSourceUserData, value: MouseControlSupport.syntheticEventTag)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
        if landing { finishGlide() }
    }

    private func finishGlide() {
        frameTimer?.invalidate()
        frameTimer = nil
        carryVertical = 0
        carryHorizontal = 0
    }

    private func stopGlide() {
        frameTimer?.invalidate()
        frameTimer = nil
        remainingVertical = 0
        remainingHorizontal = 0
        carryVertical = 0
        carryHorizontal = 0
    }

    private static func pixelField(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        return Int32(clamping: Int(min(max(value, -1_000_000), 1_000_000)))
    }

    private func handlePointerMove(_ event: CGEvent) {
        if focusFollowsPointer || !exclusions.isEmpty {
            windowResolver.refresh(at: event.location)
        }
        guard focusFollowsPointer, pressedButtons.isEmpty,
            !Self.hasBlockingModifiers(event.flags), !isExcluded(at: event.location)
        else {
            cancelFocus()
            return
        }
        cancelFocus()
        let point = event.location
        let generation = focusGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.focus(at: point, generation: generation) }
        }
        pendingFocus = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(focusDelay) / 1_000, execute: work)
    }

    private func focus(at point: CGPoint, generation: UInt64) {
        pendingFocus = nil
        guard generation == focusGeneration, focusFollowsPointer, pressedButtons.isEmpty,
            !Self.hasBlockingModifiers(CGEventSource.flagsState(.combinedSessionState))
        else { return }
        windowResolver.focusTarget(at: point) { [weak self] target in
            MainActor.assumeIsolated {
                self?.applyFocus(target, generation: generation)
            }
        }
    }

    private func applyFocus(_ target: MouseWindowResolver.FocusTarget?, generation: UInt64) {
        guard generation == focusGeneration, focusFollowsPointer, pressedButtons.isEmpty,
            !Self.hasBlockingModifiers(CGEventSource.flagsState(.combinedSessionState)),
            let target,
            let application = NSRunningApplication(
                processIdentifier: target.processID),
            !isExcluded(application), application.activationPolicy == .regular,
            !application.isTerminated, !application.isActive || !target.isFocused
        else { return }
        application.activate()
        AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
    }

    private func cancelFocus() {
        focusGeneration &+= 1
        pendingFocus?.cancel()
        pendingFocus = nil
    }

    private func handleButtonDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        pressedButtons.insert(button)
        cancelFocus()
        if button == 0 || button == 1 {
            switch trackpadMiddleClickDecision(for: event, button: button) {
            case .transform:
                middleClickSourceButton = button
                return Unmanaged.passUnretained(asMiddle(event, type: .otherMouseDown))
            case .suppress:
                suppressedMiddleClickSourceButton = button
                return nil
            case .passThrough:
                break
            }
        }
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
        if suppressedMiddleClickSourceButton == button {
            suppressedMiddleClickSourceButton = nil
            return nil
        }
        if middleClickSourceButton == button {
            middleClickSourceButton = nil
            lastMiddleClickEnd = ProcessInfo.processInfo.systemUptime
            return Unmanaged.passUnretained(asMiddle(event, type: .otherMouseUp))
        }
        if untouchedButtons.remove(button) != nil { return Unmanaged.passUnretained(event) }
        if claimedButtons.remove(button) != nil { return nil }
        return Unmanaged.passUnretained(event)
    }

    private func handleButtonDrag(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if suppressedMiddleClickSourceButton == button { return nil }
        if middleClickSourceButton == button {
            return Unmanaged.passUnretained(asMiddle(event, type: .otherMouseDragged))
        }
        return Unmanaged.passUnretained(event)
    }

    private func trackpadMiddleClickDecision(
        for event: CGEvent, button: Int
    ) -> MouseControlSupport.MiddleClickDecision {
        guard middleClick, !isExcluded(at: event.location) else { return .passThrough }
        if middleClickSourceButton == button { return .suppress }
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = TrackpadContactMonitor.shared.snapshot(at: now)
        return MouseControlSupport.middleClickDecision(
            fingerCount: snapshot.fingerCount, frameAge: snapshot.frameAge,
            settledFor: snapshot.settledFor,
            sinceLastTransform: lastMiddleClickEnd.map { now - $0 },
            systemDragEnabled: MouseControlSupport.systemThreeFingerDragEnabled())
    }

    private func asMiddle(_ event: CGEvent, type: CGEventType) -> CGEvent {
        event.type = type
        event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        return event
    }

    private func releaseHeldMiddleButton() {
        guard middleClickSourceButton != nil else { return }
        middleClickSourceButton = nil
        let point = CGEvent(source: nil)?.location ?? .zero
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(
            mouseEventSource: source, mouseType: .otherMouseUp,
            mouseCursorPosition: point, mouseButton: .center)
        event?.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        event?.setIntegerValueField(
            .eventSourceUserData, value: MouseControlSupport.syntheticEventTag)
        event?.post(tap: .cghidEventTap)
        lastMiddleClickEnd = ProcessInfo.processInfo.systemUptime
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
        guard !exclusions.isEmpty else { return false }
        return isExcluded(windowResolver.application(at: point))
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

private final class MouseWindowResolver: @unchecked Sendable {
    struct FocusTarget: @unchecked Sendable {
        let processID: pid_t
        let window: AXUIElement
        let isFocused: Bool
    }

    private struct WindowTarget: Sendable {
        let frame: CGRect?
        let processID: pid_t?
        let resolvedPoint: CGPoint
        let resolvedAt: TimeInterval
    }

    private let queryQueue = DispatchQueue(label: "com.pulkit.edith.mouse-window-resolver")
    private let lock = NSLock()
    private var cachedTarget = WindowTarget(
        frame: nil, processID: nil, resolvedPoint: .zero, resolvedAt: -.infinity)
    private var refreshInFlight = false
    private static let ownProcessID = getpid()
    private let systemElement: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.2)
        return element
    }()

    func application(at point: CGPoint) -> NSRunningApplication? {
        let processID = cachedProcessID(at: point)
        if processID == nil { refresh(at: point) }
        return processID.flatMap(NSRunningApplication.init(processIdentifier:))
            ?? NSWorkspace.shared.frontmostApplication
    }

    func refresh(at point: CGPoint) {
        lock.lock()
        let current = cachedTarget
        let now = ProcessInfo.processInfo.systemUptime
        let valid = Self.cacheHolds(current, point: point, now: now)
        if valid || refreshInFlight {
            lock.unlock()
            return
        }
        refreshInFlight = true
        lock.unlock()
        queryQueue.async { [weak self] in
            guard let self else { return }
            let target = Self.resolveWindow(at: point)
            self.lock.lock()
            self.cachedTarget = WindowTarget(
                frame: target?.frame, processID: target?.processID, resolvedPoint: point,
                resolvedAt: ProcessInfo.processInfo.systemUptime)
            self.refreshInFlight = false
            self.lock.unlock()
        }
    }

    func focusTarget(
        at point: CGPoint, completion: @escaping @Sendable (FocusTarget?) -> Void
    ) {
        queryQueue.async { [weak self] in
            let target = self?.resolveFocusTarget(at: point)
            DispatchQueue.main.async { completion(target) }
        }
    }

    func invalidate() {
        lock.lock()
        cachedTarget = WindowTarget(
            frame: nil, processID: nil, resolvedPoint: .zero, resolvedAt: -.infinity)
        lock.unlock()
    }

    private func cachedProcessID(at point: CGPoint) -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        return Self.cacheHolds(cachedTarget, point: point, now: now)
            ? cachedTarget.processID : nil
    }

    private static func cacheHolds(
        _ target: WindowTarget, point: CGPoint, now: TimeInterval
    ) -> Bool {
        guard now >= target.resolvedAt, now - target.resolvedAt < 0.5 else { return false }
        guard let frame = target.frame else { return point == target.resolvedPoint }
        return frame.contains(point)
    }

    private static func resolveWindow(at point: CGPoint) -> (frame: CGRect, processID: pid_t)? {
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for window in windows {
            guard let processID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                processID != ownProcessID,
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
            if frame.contains(point) { return (frame, processID) }
        }
        return nil
    }

    private func resolveFocusTarget(at point: CGPoint) -> FocusTarget? {
        var element: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(
                systemElement, Float(point.x), Float(point.y), &element) == .success,
            let element, let window = topLevelWindow(from: element)
        else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.2)
        var processID: pid_t = 0
        guard AXUIElementGetPid(window, &processID) == .success,
            processID != Self.ownProcessID
        else { return nil }
        var focusedValue: CFTypeRef?
        let focused =
            AXUIElementCopyAttributeValue(
                window, kAXFocusedAttribute as CFString, &focusedValue) == .success
            && (focusedValue as? Bool == true)
        return FocusTarget(processID: processID, window: window, isFocused: focused)
    }

    private func topLevelWindow(from element: AXUIElement) -> AXUIElement? {
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleValue) == .success,
            roleValue as? String == kAXWindowRole as String
        {
            return element
        }
        var windowValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXWindowAttribute as CFString, &windowValue) == .success,
            let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return nil }
        return (windowValue as! AXUIElement)
    }
}
