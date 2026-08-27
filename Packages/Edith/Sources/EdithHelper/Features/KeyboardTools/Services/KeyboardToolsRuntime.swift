import AppKit
import ApplicationServices
import CoreGraphics
import EdithKit
import Foundation

@MainActor
final class KeyboardToolsRuntime {
    private let eventTap: KeyboardToolsEventTap
    private var wakeObserver: NSObjectProtocol?

    init() {
        eventTap = KeyboardToolsEventTap(
            performTapAction: { action in
                DispatchQueue.main.async { Self.perform(action) }
            },
            publishStatus: { active, error in
                DispatchQueue.main.async { Self.publish(active: active, error: error) }
            })
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.eventTap.restart() }
        }
        syncSettings()
    }

    func syncSettings() {
        let settings = KeyboardToolsSettings.load()
        guard AXIsProcessTrusted(), settings.debounceEnabled || settings.superEnabled else {
            let cleanupError = eventTap.stop()
            Self.publish(
                active: false,
                error: AXIsProcessTrusted()
                    ? cleanupError : "Accessibility access is required.")
            return
        }
        eventTap.sync(settings)
    }

    func shutdown() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        let cleanupError = eventTap.stop()
        Self.publish(active: false, error: cleanupError)
    }

    static func restoreDisabledState() {
        do {
            try KeyboardSuperMapper().setEnabled(false)
            publish(active: false, error: nil)
        } catch {
            publish(active: false, error: error.localizedDescription)
        }
    }

    private static func perform(_ action: KeyboardSuperTapAction) {
        switch action {
        case .none:
            break
        case .escape:
            guard let source = CGEventSource(stateID: .combinedSessionState),
                let down = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)
            else { return }
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        case .openEdith:
            showPanel()
        }
    }

    private static func publish(active: Bool, error: String?) {
        let defaults = SharedDefaults.store
        defaults.set(active, forKey: AppStorageKeys.KeyboardTools.runtimeActive)
        if let error {
            defaults.set(error, forKey: AppStorageKeys.KeyboardTools.runtimeError)
        } else {
            defaults.removeObject(forKey: AppStorageKeys.KeyboardTools.runtimeError)
        }
    }
}

private final class KeyboardToolsEventTap: @unchecked Sendable {
    private enum Route {
        case pass
        case swallow
        case modify(CGEventFlags)
        case tap(KeyboardSuperTapAction)
    }

    private let lock = NSLock()
    private let mappingLock = NSLock()
    private let mapper = KeyboardSuperMapper()
    private let performTapAction: @Sendable (KeyboardSuperTapAction) -> Void
    private let publishStatus: @Sendable (Bool, String?) -> Void
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var stopping = false
    private var pendingRestart = false
    private var settings = KeyboardToolsSettings.load()
    private var debounce = KeyboardDebounceState()
    private var superKey = KeyboardSuperState()
    private var superActive = false

    init(
        performTapAction: @escaping @Sendable (KeyboardSuperTapAction) -> Void,
        publishStatus: @escaping @Sendable (Bool, String?) -> Void
    ) {
        self.performTapAction = performTapAction
        self.publishStatus = publishStatus
    }

    func sync(_ settings: KeyboardToolsSettings) {
        let shouldRestart = lock.withLock { () -> Bool in
            let changed = self.settings.superEnabled != settings.superEnabled
            self.settings = settings
            let disabled = tap.map { !CGEvent.tapIsEnabled(tap: $0) } ?? false
            return (changed || disabled) && thread != nil
        }
        if shouldRestart {
            _ = stop(restart: true)
        } else {
            start()
        }
    }

    func restart() {
        _ = stop(restart: true)
    }

    func stop() -> String? {
        stop(restart: false)
    }

    private func start() {
        let newThread = lock.withLock { () -> Thread? in
            guard thread == nil else { return nil }
            stopping = false
            pendingRestart = false
            let value = Thread { self.runEventTap() }
            value.name = "Edith Keyboard Tools"
            value.qualityOfService = .userInteractive
            thread = value
            return value
        }
        newThread?.start()
    }

    private func stop(restart: Bool) -> String? {
        let snapshot = lock.withLock { () -> (CFMachPort?, CFRunLoop?, Bool) in
            stopping = true
            pendingRestart = restart
            debounce.reset()
            superKey.reset()
            superActive = false
            return (tap, runLoop, thread != nil)
        }
        if let tap = snapshot.0 { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop = snapshot.1 {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
        if !snapshot.2 {
            lock.withLock {
                stopping = false
                pendingRestart = false
            }
        }
        let cleanupError = mappingLock.withLock { () -> String? in
            do {
                try mapper.setEnabled(false)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if restart, !snapshot.2 { start() }
        return cleanupError
    }

    private func runEventTap() {
        autoreleasepool {
            let currentRunLoop = CFRunLoopGetCurrent()
            lock.withLock { runLoop = currentRunLoop }
            guard !lock.withLock({ stopping }) else {
                finishThread()
                return
            }
            let types: [CGEventType] = [
                .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown,
                .otherMouseDown,
            ]
            let mask = types.reduce(CGEventMask(0)) {
                $0 | (CGEventMask(1) << $1.rawValue)
            }
            guard
                let eventTap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                    eventsOfInterest: mask,
                    callback: { _, type, event, context in
                        guard let context else { return Unmanaged.passUnretained(event) }
                        return Unmanaged<KeyboardToolsEventTap>.fromOpaque(context)
                            .takeUnretainedValue().route(type: type, event: event)
                    }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            else {
                var failure = "The keyboard event filter could not start."
                mappingLock.withLock {
                    do {
                        try mapper.setEnabled(false)
                    } catch {
                        failure += " \(error.localizedDescription)"
                    }
                }
                publishStatus(false, failure)
                finishThread()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            lock.withLock { tap = eventTap }
            CFRunLoopAddSource(currentRunLoop, source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            let mappingError = applyMappingIfNeeded()
            if !lock.withLock({ stopping }) {
                publishStatus(true, mappingError)
                CFRunLoopRun()
            }
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)
            CFMachPortInvalidate(eventTap)
            finishThread()
        }
    }

    private func applyMappingIfNeeded() -> String? {
        mappingLock.withLock {
            let wanted = lock.withLock { settings.superEnabled && !stopping }
            guard wanted else {
                try? mapper.setEnabled(false)
                return nil
            }
            do {
                try mapper.setEnabled(true)
                let stopped = lock.withLock { () -> Bool in
                    superActive = !stopping
                    return stopping
                }
                if stopped { try mapper.setEnabled(false) }
                return nil
            } catch {
                try? mapper.setEnabled(false)
                lock.withLock { superActive = false }
                return error.localizedDescription
            }
        }
    }

    private func finishThread() {
        let restart = lock.withLock { () -> Bool in
            tap = nil
            runLoop = nil
            thread = nil
            stopping = false
            superActive = false
            let value = pendingRestart
            pendingRestart = false
            return value
        }
        if restart { start() }
    }

    private func route(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let activeTap = lock.withLock({ stopping ? nil : tap }) {
                CGEvent.tapEnable(tap: activeTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        let route = classify(type: type, event: event)
        switch route {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .modify(let modifiers):
            event.flags.formUnion(modifiers)
            return Unmanaged.passUnretained(event)
        case .tap(let action):
            performTapAction(action)
            return nil
        }
    }

    private func classify(type: CGEventType, event: CGEvent) -> Route {
        lock.withLock {
            guard !stopping else { return .pass }
            let current = settings
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if superActive {
                switch superKey.decide(
                    type: type, keyCode: keyCode, repeatEvent: repeated,
                    timestamp: event.timestamp)
                {
                case .swallow:
                    return .swallow
                case .tap:
                    return .tap(current.superTapAction)
                case .addModifiers:
                    return .modify(current.superHoldAction.eventFlags)
                case .pass:
                    break
                }
            }
            let kind: KeyboardDebounceState.EventKind
            if type == .keyDown {
                kind = .down
            } else if type == .keyUp {
                kind = .up
            } else {
                return .pass
            }
            return debounce.shouldSuppress(
                keyCode: keyCode, repeatEvent: repeated, kind: kind,
                timestamp: event.timestamp, settings: current) ? .swallow : .pass
        }
    }
}

private final class KeyboardSuperMapper: @unchecked Sendable {
    private final class CommandWaiter: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: CLICommandResult?
        private var finished = false

        func finish(_ result: CLICommandResult?) {
            condition.lock()
            self.result = result
            finished = true
            condition.broadcast()
            condition.unlock()
        }

        func wait() -> CLICommandResult? {
            condition.lock()
            defer { condition.unlock() }
            while !finished { condition.wait() }
            return result
        }
    }

    private enum MappingError: LocalizedError {
        case conflict
        case unavailable
        case unconfirmed

        var errorDescription: String? {
            switch self {
            case .conflict:
                "Caps Lock already has a keyboard mapping. Remove it before enabling Super key."
            case .unavailable:
                "macOS did not allow the Caps Lock mapping to be changed."
            case .unconfirmed:
                "macOS did not confirm the Caps Lock mapping change."
            }
        }
    }

    private let lock = NSLock()

    func setEnabled(_ enabled: Bool) throws {
        try lock.withLock {
            let defaults = SharedDefaults.store
            let ownsMapping = defaults.bool(forKey: AppStorageKeys.KeyboardTools.mappingApplied)
            if !enabled, !ownsMapping { return }
            let report = try readMappings()
            guard
                let external = KeyboardSuperMappingSupport.consistentMappings(
                    report, ownsMapping: ownsMapping),
                let desired = KeyboardSuperMappingSupport.desiredMappings(
                    enabling: enabled, existing: external, ownsMapping: false)
            else { throw MappingError.conflict }
            if enabled {
                defaults.set(true, forKey: AppStorageKeys.KeyboardTools.mappingApplied)
            }
            let result = try run([
                "property", "--matching", "keyboard", "--set",
                KeyboardSuperMappingSupport.mappingArgument(desired),
            ])
            guard result.terminationStatus == 0 else { throw MappingError.unavailable }
            let readback = try readMappings()
            guard KeyboardSuperMappingSupport.reportConfirms(readback, expected: desired) else {
                throw MappingError.unconfirmed
            }
            defaults.set(enabled, forKey: AppStorageKeys.KeyboardTools.mappingApplied)
        }
    }

    private func readMappings() throws -> String {
        let result = try run([
            "property", "--matching", "keyboard", "--get",
            KeyboardSuperMappingSupport.property,
        ])
        guard result.terminationStatus == 0 else { throw MappingError.unavailable }
        return result.output
    }

    private func run(_ arguments: [String]) throws -> CLICommandResult {
        let waiter = CommandWaiter()
        let commandTask = Task.detached(priority: .userInitiated) {
            let result = try? await CLICommandRunner.run(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/hidutil"),
                    arguments: arguments,
                    environment: ProcessInfo.processInfo.environment,
                    timeout: 3,
                    maximumOutputBytes: 262_144,
                    terminatesProcessGroup: true
                )
            ) { _ in }
            waiter.finish(result)
        }
        defer { commandTask.cancel() }
        guard let result = waiter.wait() else { throw MappingError.unavailable }
        return result
    }
}
