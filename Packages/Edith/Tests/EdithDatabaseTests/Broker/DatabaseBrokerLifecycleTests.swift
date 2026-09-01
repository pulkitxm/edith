import Darwin
import Dispatch
import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerLifecycleTestError: Error {
    case registrationFailure
}

private enum DatabaseBrokerLifecycleTestEvent: Equatable {
    case suppress(Int32)
    case restore(Int32)
    case createSource(Int32)
    case activateSource(Int32)
    case cancelSourceStarted(Int32, Bool)
    case cancelSourceCompleted(Int32)
    case armWatchdog(UInt64)
    case cancelWatchdog
    case shutdown(DatabaseBrokerShutdownRequest)
    case forceExit
}

private final class DatabaseBrokerLifecycleTestHarness: @unchecked Sendable {
    private let stateLock = NSLock()
    private let monotonicTime: UInt64
    private let failedSuppression: Int32?
    private let failedRegistration: Int32?
    private let blockedCancellation: Int32?
    private let cancellationStarted: DispatchSemaphore?
    private let cancellationRelease: DispatchSemaphore?
    private let watchdogArmStarted: DispatchSemaphore?
    private let watchdogArmRelease: DispatchSemaphore?
    private var recordedEvents: [DatabaseBrokerLifecycleTestEvent] = []
    private var signalHandlers: [Int32: @Sendable () -> Void] = [:]
    private var watchdogHandler: (@Sendable () -> Void)?

    init(
        monotonicTime: UInt64 = 41,
        failedSuppression: Int32? = nil,
        failedRegistration: Int32? = nil,
        blockedCancellation: Int32? = nil,
        cancellationStarted: DispatchSemaphore? = nil,
        cancellationRelease: DispatchSemaphore? = nil,
        watchdogArmStarted: DispatchSemaphore? = nil,
        watchdogArmRelease: DispatchSemaphore? = nil
    ) {
        self.monotonicTime = monotonicTime
        self.failedSuppression = failedSuppression
        self.failedRegistration = failedRegistration
        self.blockedCancellation = blockedCancellation
        self.cancellationStarted = cancellationStarted
        self.cancellationRelease = cancellationRelease
        self.watchdogArmStarted = watchdogArmStarted
        self.watchdogArmRelease = watchdogArmRelease
    }

    var events: [DatabaseBrokerLifecycleTestEvent] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedEvents
    }

    var dependencies: DatabaseBrokerLifecycleDependencies {
        DatabaseBrokerLifecycleDependencies(
            suppressDefaultSignalAction: { signalNumber in
                self.record(.suppress(signalNumber))
                return signalNumber != self.failedSuppression
            },
            restoreDefaultSignalAction: { signalNumber in
                self.record(.restore(signalNumber))
            },
            makeSignalRegistration: { signalNumber, handler in
                self.record(.createSource(signalNumber))
                if signalNumber == self.failedRegistration {
                    throw DatabaseBrokerLifecycleTestError.registrationFailure
                }
                self.storeSignalHandler(handler, for: signalNumber)
                return DatabaseBrokerLifecycleSignalRegistration(
                    activate: {
                        self.record(.activateSource(signalNumber))
                    },
                    cancel: { wasActivated in
                        self.record(.cancelSourceStarted(signalNumber, wasActivated))
                        if signalNumber == self.blockedCancellation {
                            self.cancellationStarted?.signal()
                            self.cancellationRelease?.wait()
                        }
                        self.record(.cancelSourceCompleted(signalNumber))
                    })
            },
            monotonicNanoseconds: {
                self.monotonicTime
            },
            armWatchdog: { deadline, handler in
                self.record(.armWatchdog(deadline))
                self.watchdogArmStarted?.signal()
                self.watchdogArmRelease?.wait()
                self.storeWatchdogHandler(handler)
                return DatabaseBrokerLifecycleCancellation {
                    self.record(.cancelWatchdog)
                }
            },
            forceExit: {
                self.record(.forceExit)
            })
    }

    func recordShutdown(_ request: DatabaseBrokerShutdownRequest) {
        record(.shutdown(request))
    }

    func sendSignal(_ signalNumber: Int32) {
        stateLock.lock()
        let handler = signalHandlers[signalNumber]
        stateLock.unlock()
        handler?()
    }

    func fireWatchdog() {
        stateLock.lock()
        let handler = watchdogHandler
        stateLock.unlock()
        handler?()
    }

    private func record(_ event: DatabaseBrokerLifecycleTestEvent) {
        stateLock.lock()
        recordedEvents.append(event)
        stateLock.unlock()
    }

    private func storeSignalHandler(
        _ handler: @escaping @Sendable () -> Void,
        for signalNumber: Int32
    ) {
        stateLock.lock()
        signalHandlers[signalNumber] = handler
        stateLock.unlock()
    }

    private func storeWatchdogHandler(
        _ handler: @escaping @Sendable () -> Void
    ) {
        stateLock.lock()
        watchdogHandler = handler
        stateLock.unlock()
    }
}

private final class DatabaseBrokerLifecycleLockedCounter: @unchecked Sendable {
    private let stateLock = NSLock()
    private var value = 0

    func increment() {
        stateLock.lock()
        value += 1
        stateLock.unlock()
    }

    var count: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return value
    }
}

private final class DatabaseBrokerLifecycleLockedFlag: @unchecked Sendable {
    private let stateLock = NSLock()
    private var value = false

    func set(_ value: Bool) {
        stateLock.lock()
        self.value = value
        stateLock.unlock()
    }

    var currentValue: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return value
    }
}

@Suite struct DatabaseBrokerLifecycleTests {
    @Test func suppressesSignalDefaultsBeforeActivatingOwnedSources() throws {
        let harness = DatabaseBrokerLifecycleTestHarness()
        let lifecycle = try DatabaseBrokerLifecycle.activate(
            dependencies: harness.dependencies,
            onShutdownRequest: { request in harness.recordShutdown(request) })

        #expect(
            harness.events == [
                .suppress(SIGTERM),
                .suppress(SIGINT),
                .createSource(SIGTERM),
                .createSource(SIGINT),
                .activateSource(SIGTERM),
                .activateSource(SIGINT),
            ])

        lifecycle.cleanup()
    }

    @Test func firstSignalArmsTenSecondWatchdogBeforeShutdownCallback() throws {
        let harness = DatabaseBrokerLifecycleTestHarness(monotonicTime: 73)
        let lifecycle = try DatabaseBrokerLifecycle.activate(
            dependencies: harness.dependencies,
            onShutdownRequest: { request in harness.recordShutdown(request) })

        harness.sendSignal(SIGTERM)
        harness.sendSignal(SIGINT)

        #expect(lifecycle.firstShutdownRequest == .signal(SIGTERM))
        let deadline = 73 + DatabaseBrokerLifecycle.watchdogBudgetNanoseconds
        let events = harness.events
        let armIndex = try #require(events.firstIndex(of: .armWatchdog(deadline)))
        let shutdownIndex = try #require(events.firstIndex(of: .shutdown(.signal(SIGTERM))))
        #expect(armIndex < shutdownIndex)
        #expect(events.filter { $0 == .armWatchdog(deadline) }.count == 1)
        #expect(events.filter { $0 == .shutdown(.signal(SIGTERM)) }.count == 1)
        #expect(!events.contains(.shutdown(.signal(SIGINT))))

        lifecycle.cleanup()
    }

    @Test func explicitRequestWinsOverLaterSignals() throws {
        let harness = DatabaseBrokerLifecycleTestHarness()
        let lifecycle = try DatabaseBrokerLifecycle.activate(
            dependencies: harness.dependencies,
            onShutdownRequest: { request in harness.recordShutdown(request) })

        #expect(lifecycle.requestShutdown())
        harness.sendSignal(SIGTERM)

        #expect(lifecycle.firstShutdownRequest == .requested)
        #expect(harness.events.filter { $0 == .shutdown(.requested) }.count == 1)
        #expect(!harness.events.contains(.shutdown(.signal(SIGTERM))))

        lifecycle.cleanup()
    }

    @Test func concurrentRequestsClaimExactlyOneShutdown() throws {
        let harness = DatabaseBrokerLifecycleTestHarness()
        let lifecycle = try DatabaseBrokerLifecycle.activate(
            dependencies: harness.dependencies,
            onShutdownRequest: { request in harness.recordShutdown(request) })
        let accepted = DatabaseBrokerLifecycleLockedCounter()

        DispatchQueue.concurrentPerform(iterations: 128) { index in
            if lifecycle.requestShutdown(.signal(Int32(index + 1))) {
                accepted.increment()
            }
        }

        #expect(accepted.count == 1)
        #expect(
            harness.events.filter {
                if case .armWatchdog = $0 { return true }
                return false
            }.count == 1)
        #expect(
            harness.events.filter {
                if case .shutdown = $0 { return true }
                return false
            }.count == 1)

        lifecycle.cleanup()
    }

    @Test func saturatesWatchdogDeadlineAtMaximumUptime() {
        #expect(DatabaseBrokerLifecycle.watchdogDeadline(from: 5) == 10_000_000_005)
        #expect(
            DatabaseBrokerLifecycle.watchdogDeadline(
                from: UInt64.max - 3) == UInt64.max)
    }

    @Test func cleanupWaitsForSourceCancellationBeforeRestoringDefaults() throws {
        let cancellationStarted = DispatchSemaphore(value: 0)
        let cancellationRelease = DispatchSemaphore(value: 0)
        let cleanupCompleted = DispatchSemaphore(value: 0)
        let cleanupResult = DatabaseBrokerLifecycleLockedFlag()
        let harness = DatabaseBrokerLifecycleTestHarness(
            blockedCancellation: SIGTERM,
            cancellationStarted: cancellationStarted,
            cancellationRelease: cancellationRelease)
        let lifecycle = try DatabaseBrokerLifecycle.activate(
            dependencies: harness.dependencies,
            onShutdownRequest: { request in harness.recordShutdown(request) })

        DispatchQueue.global().async {
            cleanupResult.set(lifecycle.cleanup())
            cleanupCompleted.signal()
        }

        #expect(cancellationStarted.wait(timeout: .now() + 2) == .success)
        #expect(
            !harness.events.contains {
                if case .restore = $0 { return true }
                return false
            })
        cancellationRelease.signal()
        #expect(cleanupCompleted.wait(timeout: .now() + 2) == .success)

        #expect(cleanupResult.currentValue)
        let events = harness.events
        let termCompleted = try #require(
            events.firstIndex(of: .cancelSourceCompleted(SIGTERM)))
        let interruptCompleted = try #require(
            events.firstIndex(of: .cancelSourceCompleted(SIGINT)))
        let firstRestore = try #require(
            events.firstIndex {
                if case .restore = $0 { return true }
                return false
            })
        #expect(termCompleted < firstRestore)
        #expect(interruptCompleted < firstRestore)
        #expect(!lifecycle.cleanup())
    }

    @Test func watchdogDisarmIsIndependentAndIdempotent() throws {
        let harness = DatabaseBrokerLifecycleTestHarness()
        let lifecycle = try DatabaseBrokerLifecycle.activate(
            dependencies: harness.dependencies,
            onShutdownRequest: { request in harness.recordShutdown(request) })

        #expect(!lifecycle.disarmWatchdog())
        #expect(lifecycle.requestShutdown())
        #expect(lifecycle.disarmWatchdog())
        #expect(!lifecycle.disarmWatchdog())
        harness.fireWatchdog()

        #expect(harness.events.filter { $0 == .cancelWatchdog }.count == 1)
        #expect(!harness.events.contains(.forceExit))
        #expect(lifecycle.cleanup())
        #expect(harness.events.filter { $0 == .cancelWatchdog }.count == 1)
    }

    @Test func cleanupIsIdempotentAndRejectsFutureShutdownRequests() throws {
        let harness = DatabaseBrokerLifecycleTestHarness()
        let lifecycle = try DatabaseBrokerLifecycle.activate(
            dependencies: harness.dependencies,
            onShutdownRequest: { request in harness.recordShutdown(request) })

        #expect(lifecycle.cleanup())
        #expect(!lifecycle.cleanup())
        #expect(!lifecycle.requestShutdown())

        let events = harness.events
        #expect(events.filter { $0 == .restore(SIGTERM) }.count == 1)
        #expect(events.filter { $0 == .restore(SIGINT) }.count == 1)
        #expect(
            events.filter {
                if case .shutdown = $0 { return true }
                return false
            }.isEmpty)
    }

    @Test func signalRequestsShutdownWhileStartupIsBlocked() throws {
        let startupEntered = DispatchSemaphore(value: 0)
        let startupRelease = DispatchSemaphore(value: 0)
        let startupCompleted = DispatchSemaphore(value: 0)
        let harness = DatabaseBrokerLifecycleTestHarness()
        let lifecycle = try DatabaseBrokerLifecycle.activate(
            dependencies: harness.dependencies,
            onShutdownRequest: { request in harness.recordShutdown(request) })

        DispatchQueue.global().async {
            startupEntered.signal()
            startupRelease.wait()
            startupCompleted.signal()
        }

        #expect(startupEntered.wait(timeout: .now() + 2) == .success)
        harness.sendSignal(SIGINT)

        #expect(lifecycle.firstShutdownRequest == .signal(SIGINT))
        #expect(harness.events.contains(.shutdown(.signal(SIGINT))))
        #expect(
            harness.events.contains {
                if case .armWatchdog = $0 { return true }
                return false
            })
        startupRelease.signal()
        #expect(startupCompleted.wait(timeout: .now() + 2) == .success)

        lifecycle.cleanup()
    }

    @Test func watchdogForcesExitOnlyOnceUntilCleanup() throws {
        let harness = DatabaseBrokerLifecycleTestHarness()
        let lifecycle = try DatabaseBrokerLifecycle.activate(
            dependencies: harness.dependencies,
            onShutdownRequest: { request in harness.recordShutdown(request) })

        #expect(lifecycle.requestShutdown())
        harness.fireWatchdog()
        harness.fireWatchdog()

        #expect(harness.events.filter { $0 == .forceExit }.count == 1)
        lifecycle.cleanup()
        harness.fireWatchdog()
        #expect(harness.events.filter { $0 == .forceExit }.count == 1)
    }

    @Test func shutdownCallbackWaitsForSynchronousWatchdogArm() throws {
        let armStarted = DispatchSemaphore(value: 0)
        let armRelease = DispatchSemaphore(value: 0)
        let requestCompleted = DispatchSemaphore(value: 0)
        let harness = DatabaseBrokerLifecycleTestHarness(
            watchdogArmStarted: armStarted,
            watchdogArmRelease: armRelease)
        let lifecycle = try DatabaseBrokerLifecycle.activate(
            dependencies: harness.dependencies,
            onShutdownRequest: { request in harness.recordShutdown(request) })

        DispatchQueue.global().async {
            lifecycle.requestShutdown()
            requestCompleted.signal()
        }

        #expect(armStarted.wait(timeout: .now() + 2) == .success)
        #expect(!harness.events.contains(.shutdown(.requested)))
        armRelease.signal()
        #expect(requestCompleted.wait(timeout: .now() + 2) == .success)
        #expect(harness.events.contains(.shutdown(.requested)))

        lifecycle.cleanup()
    }

    @Test func disarmDuringWatchdogArmCancelsNewRegistration() throws {
        let armStarted = DispatchSemaphore(value: 0)
        let armRelease = DispatchSemaphore(value: 0)
        let requestCompleted = DispatchSemaphore(value: 0)
        let harness = DatabaseBrokerLifecycleTestHarness(
            watchdogArmStarted: armStarted,
            watchdogArmRelease: armRelease)
        let lifecycle = try DatabaseBrokerLifecycle.activate(
            dependencies: harness.dependencies,
            onShutdownRequest: { request in harness.recordShutdown(request) })

        DispatchQueue.global().async {
            lifecycle.requestShutdown()
            requestCompleted.signal()
        }

        #expect(armStarted.wait(timeout: .now() + 2) == .success)
        #expect(lifecycle.disarmWatchdog())
        #expect(!lifecycle.disarmWatchdog())
        armRelease.signal()
        #expect(requestCompleted.wait(timeout: .now() + 2) == .success)

        #expect(harness.events.filter { $0 == .cancelWatchdog }.count == 1)
        harness.fireWatchdog()
        #expect(!harness.events.contains(.forceExit))

        lifecycle.cleanup()
    }

    @Test func suppressionFailureRestoresEarlierDefault() {
        let harness = DatabaseBrokerLifecycleTestHarness(failedSuppression: SIGINT)

        #expect(throws: DatabaseBrokerLifecycleError.signalSuppressionFailed(SIGINT)) {
            _ = try DatabaseBrokerLifecycle.activate(
                dependencies: harness.dependencies,
                onShutdownRequest: { request in harness.recordShutdown(request) })
        }
        #expect(
            harness.events == [
                .suppress(SIGTERM),
                .suppress(SIGINT),
                .restore(SIGTERM),
            ])
    }

    @Test func registrationFailureCancelsSourcesBeforeRestoringDefaults() {
        let harness = DatabaseBrokerLifecycleTestHarness(failedRegistration: SIGINT)

        #expect(throws: DatabaseBrokerLifecycleError.signalRegistrationFailed(SIGINT)) {
            _ = try DatabaseBrokerLifecycle.activate(
                dependencies: harness.dependencies,
                onShutdownRequest: { request in harness.recordShutdown(request) })
        }

        let events = harness.events
        let cancellation = events.firstIndex(of: .cancelSourceCompleted(SIGTERM))
        let firstRestore = events.firstIndex {
            if case .restore = $0 { return true }
            return false
        }
        #expect(cancellation != nil)
        #expect(firstRestore != nil)
        if let cancellation, let firstRestore {
            #expect(cancellation < firstRestore)
        }
        #expect(events.filter { $0 == .restore(SIGTERM) }.count == 1)
        #expect(events.filter { $0 == .restore(SIGINT) }.count == 1)
    }
}
