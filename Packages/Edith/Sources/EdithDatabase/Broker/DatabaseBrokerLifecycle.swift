import Darwin
import Dispatch
import Foundation

enum DatabaseBrokerShutdownRequest: Equatable, Sendable {
    case requested
    case signal(Int32)
}

enum DatabaseBrokerLifecycleError: Error, Equatable, Sendable {
    case signalSuppressionFailed(Int32)
    case signalRegistrationFailed(Int32)
}

final class DatabaseBrokerLifecycleSignalRegistration: @unchecked Sendable {
    private enum State {
        case inactive
        case activating
        case active
        case cancelAfterActivation
        case cancelled
    }

    private let stateLock = NSLock()
    private let activateHandler: @Sendable () -> Void
    private let cancelHandler: @Sendable (Bool) -> Void
    private var state = State.inactive

    init(
        activate: @escaping @Sendable () -> Void,
        cancel: @escaping @Sendable (Bool) -> Void
    ) {
        activateHandler = activate
        cancelHandler = cancel
    }

    func activate() {
        stateLock.lock()
        guard case .inactive = state else {
            stateLock.unlock()
            return
        }
        state = .activating
        stateLock.unlock()

        activateHandler()

        stateLock.lock()
        let shouldCancel: Bool
        if case .cancelAfterActivation = state {
            state = .cancelled
            shouldCancel = true
        } else {
            state = .active
            shouldCancel = false
        }
        stateLock.unlock()

        if shouldCancel {
            cancelHandler(true)
        }
    }

    func cancel() {
        stateLock.lock()
        let wasActivated: Bool
        switch state {
        case .inactive:
            state = .cancelled
            wasActivated = false
        case .activating:
            state = .cancelAfterActivation
            stateLock.unlock()
            return
        case .active:
            state = .cancelled
            wasActivated = true
        case .cancelAfterActivation, .cancelled:
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        cancelHandler(wasActivated)
    }
}

final class DatabaseBrokerLifecycleCancellation: @unchecked Sendable {
    private let stateLock = NSLock()
    private let cancelHandler: @Sendable () -> Void
    private var isCancelled = false

    init(cancel: @escaping @Sendable () -> Void) {
        cancelHandler = cancel
    }

    func cancel() {
        stateLock.lock()
        guard !isCancelled else {
            stateLock.unlock()
            return
        }
        isCancelled = true
        stateLock.unlock()
        cancelHandler()
    }
}

struct DatabaseBrokerLifecycleDependencies: Sendable {
    let suppressDefaultSignalAction: @Sendable (Int32) -> Bool
    let restoreDefaultSignalAction: @Sendable (Int32) -> Void
    let makeSignalRegistration:
        @Sendable (
            Int32,
            @escaping @Sendable () -> Void
        ) throws -> DatabaseBrokerLifecycleSignalRegistration
    let monotonicNanoseconds: @Sendable () -> UInt64
    let armWatchdog:
        @Sendable (
            UInt64,
            @escaping @Sendable () -> Void
        ) -> DatabaseBrokerLifecycleCancellation
    let forceExit: @Sendable () -> Void

    static func live() -> DatabaseBrokerLifecycleDependencies {
        let signalQueue = DispatchQueue(
            label: "com.pulkitxm.edith.database-broker.lifecycle.signals")
        let signalDeliveryQueue = DispatchQueue(
            label: "com.pulkitxm.edith.database-broker.lifecycle.signal-delivery")
        let watchdogQueue = DispatchQueue(
            label: "com.pulkitxm.edith.database-broker.lifecycle.watchdog")
        return DatabaseBrokerLifecycleDependencies(
            suppressDefaultSignalAction: { signalNumber in
                unsafeBitCast(
                    Darwin.signal(signalNumber, SIG_IGN),
                    to: Int.self) != -1
            },
            restoreDefaultSignalAction: { signalNumber in
                _ = Darwin.signal(signalNumber, SIG_DFL)
            },
            makeSignalRegistration: { signalNumber, handler in
                let source = DispatchSource.makeSignalSource(
                    signal: signalNumber,
                    queue: signalQueue)
                let cancellationCompleted = DispatchSemaphore(value: 0)
                source.setEventHandler {
                    signalDeliveryQueue.async(execute: handler)
                }
                source.setCancelHandler {
                    cancellationCompleted.signal()
                }
                return DatabaseBrokerLifecycleSignalRegistration(
                    activate: {
                        source.activate()
                    },
                    cancel: { wasActivated in
                        source.cancel()
                        if !wasActivated {
                            source.activate()
                        }
                        cancellationCompleted.wait()
                    })
            },
            monotonicNanoseconds: {
                DispatchTime.now().uptimeNanoseconds
            },
            armWatchdog: { deadline, handler in
                let source = DispatchSource.makeTimerSource(queue: watchdogQueue)
                source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
                source.setEventHandler(handler: handler)
                source.activate()
                return DatabaseBrokerLifecycleCancellation {
                    source.cancel()
                }
            },
            forceExit: {
                Darwin._exit(EXIT_FAILURE)
            })
    }
}

final class DatabaseBrokerLifecycle: @unchecked Sendable {
    static let watchdogBudgetNanoseconds: UInt64 = 10_000_000_000
    static let handledSignals = [SIGTERM, SIGINT]

    private struct State {
        var signalRegistrations: [DatabaseBrokerLifecycleSignalRegistration] = []
        var suppressedSignals: [Int32] = []
        var firstShutdownRequest: DatabaseBrokerShutdownRequest?
        var watchdog: DatabaseBrokerLifecycleCancellation?
        var watchdogIsDisarmed = false
        var forceExitWasRequested = false
        var isCleanedUp = false
    }

    private let stateLock = NSLock()
    private let dependencies: DatabaseBrokerLifecycleDependencies
    private let shutdownRequestHandler: @Sendable (DatabaseBrokerShutdownRequest) -> Void
    private var state = State()

    private init(
        dependencies: DatabaseBrokerLifecycleDependencies,
        shutdownRequestHandler: @escaping @Sendable (DatabaseBrokerShutdownRequest) -> Void
    ) {
        self.dependencies = dependencies
        self.shutdownRequestHandler = shutdownRequestHandler
    }

    static func activate(
        dependencies: DatabaseBrokerLifecycleDependencies = .live(),
        onShutdownRequest:
            @escaping @Sendable (DatabaseBrokerShutdownRequest) -> Void
    ) throws -> DatabaseBrokerLifecycle {
        let lifecycle = DatabaseBrokerLifecycle(
            dependencies: dependencies,
            shutdownRequestHandler: onShutdownRequest)
        try lifecycle.installSignalHandling()
        return lifecycle
    }

    var firstShutdownRequest: DatabaseBrokerShutdownRequest? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.firstShutdownRequest
    }

    @discardableResult
    func requestShutdown(
        _ request: DatabaseBrokerShutdownRequest = .requested
    ) -> Bool {
        stateLock.lock()
        guard !state.isCleanedUp, state.firstShutdownRequest == nil else {
            stateLock.unlock()
            return false
        }
        state.firstShutdownRequest = request
        stateLock.unlock()

        let deadline = Self.watchdogDeadline(
            from: dependencies.monotonicNanoseconds())
        let watchdog = dependencies.armWatchdog(deadline) { [weak self] in
            self?.watchdogFired()
        }

        stateLock.lock()
        let shouldRetainWatchdog =
            !state.isCleanedUp && !state.watchdogIsDisarmed
        if shouldRetainWatchdog {
            state.watchdog = watchdog
        }
        stateLock.unlock()

        if !shouldRetainWatchdog {
            watchdog.cancel()
        }
        shutdownRequestHandler(request)
        return true
    }

    @discardableResult
    func disarmWatchdog() -> Bool {
        stateLock.lock()
        guard
            state.firstShutdownRequest != nil,
            !state.watchdogIsDisarmed
        else {
            stateLock.unlock()
            return false
        }
        state.watchdogIsDisarmed = true
        let watchdog = state.watchdog
        state.watchdog = nil
        stateLock.unlock()

        watchdog?.cancel()
        return true
    }

    @discardableResult
    func cleanup() -> Bool {
        stateLock.lock()
        guard !state.isCleanedUp else {
            stateLock.unlock()
            return false
        }
        state.isCleanedUp = true
        state.watchdogIsDisarmed = true
        let watchdog = state.watchdog
        state.watchdog = nil
        let registrations = state.signalRegistrations
        state.signalRegistrations = []
        let suppressedSignals = state.suppressedSignals
        state.suppressedSignals = []
        stateLock.unlock()

        watchdog?.cancel()
        for registration in registrations {
            registration.cancel()
        }
        for signalNumber in suppressedSignals.reversed() {
            dependencies.restoreDefaultSignalAction(signalNumber)
        }
        return true
    }

    deinit {
        cleanup()
    }

    static func watchdogDeadline(from monotonicNanoseconds: UInt64) -> UInt64 {
        let (deadline, overflow) = monotonicNanoseconds.addingReportingOverflow(
            watchdogBudgetNanoseconds)
        return overflow ? UInt64.max : deadline
    }

    private func installSignalHandling() throws {
        var suppressedSignals: [Int32] = []
        for signalNumber in Self.handledSignals {
            guard dependencies.suppressDefaultSignalAction(signalNumber) else {
                for suppressedSignal in suppressedSignals.reversed() {
                    dependencies.restoreDefaultSignalAction(suppressedSignal)
                }
                throw DatabaseBrokerLifecycleError.signalSuppressionFailed(signalNumber)
            }
            suppressedSignals.append(signalNumber)
        }

        var registrations: [DatabaseBrokerLifecycleSignalRegistration] = []
        for signalNumber in Self.handledSignals {
            do {
                let registration = try dependencies.makeSignalRegistration(signalNumber) {
                    [weak self] in
                    self?.requestShutdown(.signal(signalNumber))
                }
                registrations.append(registration)
            } catch {
                for registration in registrations {
                    registration.cancel()
                }
                for suppressedSignal in suppressedSignals.reversed() {
                    dependencies.restoreDefaultSignalAction(suppressedSignal)
                }
                throw DatabaseBrokerLifecycleError.signalRegistrationFailed(signalNumber)
            }
        }

        stateLock.lock()
        state.signalRegistrations = registrations
        state.suppressedSignals = suppressedSignals
        stateLock.unlock()

        for registration in registrations {
            registration.activate()
        }
    }

    private func watchdogFired() {
        stateLock.lock()
        guard
            state.firstShutdownRequest != nil,
            !state.watchdogIsDisarmed,
            !state.isCleanedUp,
            !state.forceExitWasRequested
        else {
            stateLock.unlock()
            return
        }
        state.forceExitWasRequested = true
        stateLock.unlock()
        dependencies.forceExit()
    }
}
