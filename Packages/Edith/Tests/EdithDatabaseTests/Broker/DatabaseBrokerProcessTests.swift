import Darwin
import EdithCore
import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerProcessTestError: Error, Sendable {
    case appDirectories
    case lifecycle
    case paths
    case startup
}

private final class DatabaseBrokerProcessTestLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    @discardableResult
    func update<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.withLock {
            operation(&storedValue)
        }
    }
}

private final class DatabaseBrokerProcessTestEventLog: @unchecked Sendable {
    private struct State {
        var events: [String] = []
        var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    }

    private let state = DatabaseBrokerProcessTestLockedValue(State())

    var events: [String] {
        state.value.events
    }

    func append(_ event: String) {
        let waiters = state.update { state in
            state.events.append(event)
            return state.waiters.removeValue(forKey: event) ?? []
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait(for event: String) async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.update { state in
                if state.events.contains(event) {
                    return true
                }
                state.waiters[event, default: []].append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private actor DatabaseBrokerProcessTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class DatabaseBrokerProcessTestLifecycle: @unchecked Sendable {
    private struct State {
        var firstShutdownRequest: DatabaseBrokerShutdownRequest?
        var shutdownHandler: (@Sendable (DatabaseBrokerShutdownRequest) -> Void)?
        var isCleanedUp = false
    }

    private let eventLog: DatabaseBrokerProcessTestEventLog
    private let state = DatabaseBrokerProcessTestLockedValue(State())

    init(eventLog: DatabaseBrokerProcessTestEventLog) {
        self.eventLog = eventLog
    }

    func processLifecycle(
        shutdownHandler: @escaping @Sendable (DatabaseBrokerShutdownRequest) -> Void
    ) -> DatabaseBrokerProcessLifecycle {
        state.update { state in
            state.shutdownHandler = shutdownHandler
        }
        return DatabaseBrokerProcessLifecycle(
            firstShutdownRequest: {
                self.state.value.firstShutdownRequest
            },
            requestShutdown: { request in
                self.requestShutdown(request, event: "lifecycle-request")
            },
            disarmWatchdog: {
                self.eventLog.append("lifecycle-disarm")
                return true
            },
            cleanup: {
                let shouldRecord = self.state.update { state in
                    guard !state.isCleanedUp else { return false }
                    state.isCleanedUp = true
                    state.shutdownHandler = nil
                    return true
                }
                if shouldRecord {
                    self.eventLog.append("lifecycle-cleanup")
                }
                return shouldRecord
            })
    }

    func signal(_ signalNumber: Int32) {
        _ = requestShutdown(
            .signal(signalNumber),
            event: "lifecycle-signal-\(signalNumber)")
    }

    func request() {
        _ = requestShutdown(.requested, event: "lifecycle-external-request")
    }

    private func requestShutdown(
        _ request: DatabaseBrokerShutdownRequest,
        event: String
    ) -> Bool {
        let handler = state.update {
            state -> (
                @Sendable (
                    DatabaseBrokerShutdownRequest
                ) -> Void
            )? in
            guard !state.isCleanedUp, state.firstShutdownRequest == nil else {
                return nil
            }
            state.firstShutdownRequest = request
            return state.shutdownHandler
        }
        guard let handler else { return false }
        eventLog.append(event)
        handler(request)
        return true
    }
}

private final class DatabaseBrokerProcessTestRuntime: @unchecked Sendable {
    typealias StartHandler =
        @Sendable (DatabaseBrokerProcessTestRuntime) async throws -> Void

    private struct State {
        var isStopped = false
        var shutdownReason: DatabaseBrokerRuntimeShutdownReason?
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
        var observeShutdownRequest: (@Sendable (DatabaseBrokerRuntimeShutdownReason) -> Void)?
    }

    private let eventLog: DatabaseBrokerProcessTestEventLog
    private let startHandler: StartHandler
    private let state = DatabaseBrokerProcessTestLockedValue(State())

    init(
        eventLog: DatabaseBrokerProcessTestEventLog,
        start: @escaping StartHandler
    ) {
        self.eventLog = eventLog
        startHandler = start
    }

    func processRuntime(
        observeShutdownRequest:
            @escaping @Sendable (DatabaseBrokerRuntimeShutdownReason) -> Void
    ) -> DatabaseBrokerProcessRuntime {
        state.update { state in
            state.observeShutdownRequest = observeShutdownRequest
        }
        return DatabaseBrokerProcessRuntime(
            start: {
                self.eventLog.append("runtime-start")
                try await self.startHandler(self)
            },
            shutdown: {
                self.eventLog.append("runtime-shutdown")
                self.finish(reason: .requested)
            },
            waitUntilStopped: {
                self.eventLog.append("runtime-wait")
                await self.waitUntilStopped()
            },
            shutdownReason: {
                self.state.value.shutdownReason
            })
    }

    func finish(reason: DatabaseBrokerRuntimeShutdownReason) {
        let outcome = state.update {
            state -> (
                [CheckedContinuation<Void, Never>],
                (@Sendable (DatabaseBrokerRuntimeShutdownReason) -> Void)?
            )? in
            guard !state.isStopped else { return nil }
            state.isStopped = true
            state.shutdownReason = reason
            let waiters = state.stopWaiters
            state.stopWaiters.removeAll(keepingCapacity: false)
            eventLog.append("runtime-stopped-\(eventName(for: reason))")
            return (waiters, state.observeShutdownRequest)
        }
        guard let outcome else { return }
        outcome.1?(reason)
        for waiter in outcome.0 {
            waiter.resume()
        }
    }

    func finishWithoutReason() {
        let waiters = state.update { state -> [CheckedContinuation<Void, Never>]? in
            guard !state.isStopped else { return nil }
            state.isStopped = true
            let waiters = state.stopWaiters
            state.stopWaiters.removeAll(keepingCapacity: false)
            eventLog.append("runtime-stopped-without-reason")
            return waiters
        }
        guard let waiters else { return }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.update { state in
                if state.isStopped {
                    return true
                }
                state.stopWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func eventName(
        for reason: DatabaseBrokerRuntimeShutdownReason
    ) -> String {
        switch reason {
        case .requested:
            return "requested"
        case .startupFailure:
            return "startup-failure"
        case .acceptFailure:
            return "accept-failure"
        case .peerVersionMismatch:
            return "peer-version-mismatch"
        }
    }
}

private struct DatabaseBrokerProcessTestSystem: Sendable {
    let eventLog: DatabaseBrokerProcessTestEventLog
    let lifecycle: DatabaseBrokerProcessTestLifecycle
    let runtime: DatabaseBrokerProcessTestRuntime

    init(
        start:
            @escaping DatabaseBrokerProcessTestRuntime.StartHandler
    ) {
        let eventLog = DatabaseBrokerProcessTestEventLog()
        self.eventLog = eventLog
        lifecycle = DatabaseBrokerProcessTestLifecycle(eventLog: eventLog)
        runtime = DatabaseBrokerProcessTestRuntime(
            eventLog: eventLog,
            start: start)
    }

    func dependencies(
        lifecycleError: DatabaseBrokerProcessTestError? = nil,
        prepareAppDirectories:
            @escaping @Sendable () throws -> Void = {},
        preparePaths: @escaping @Sendable () throws -> Void = {}
    ) -> DatabaseBrokerProcessDependencies {
        DatabaseBrokerProcessDependencies(
            setRestrictiveFileCreationMask: {
                eventLog.append("umask")
            },
            makeAppDirectories: {
                self.eventLog.append("app-directories-make")
                return AppDirectories(
                    homeDirectory: URL(fileURLWithPath: "/private/tmp/edith-process-test"))
            },
            makePaths: { directories in
                self.eventLog.append("paths-make")
                return DatabaseBrokerPaths(directories: directories)
            },
            makeRuntime: { _, observeShutdownRequest in
                self.eventLog.append("runtime-make")
                return self.runtime.processRuntime(
                    observeShutdownRequest: observeShutdownRequest)
            },
            activateLifecycle: { shutdownHandler in
                self.eventLog.append("lifecycle-activate")
                if let lifecycleError {
                    throw lifecycleError
                }
                return self.lifecycle.processLifecycle(
                    shutdownHandler: shutdownHandler)
            },
            prepareAppDirectories: { _ in
                self.eventLog.append("app-directories-prepare")
                try prepareAppDirectories()
            },
            preparePaths: { _ in
                self.eventLog.append("paths-prepare")
                try preparePaths()
            })
    }
}

@Suite(.serialized)
struct DatabaseBrokerProcessTests {
    @Test func liveAdaptersCoverEveryOnboardedProduct() {
        let products = Set(DatabaseBrokerLiveAdapterFactory.make().flatMap(\.products))

        #expect(products.isSuperset(of: DatabaseConnectionDraft.supportedProducts))
    }

    @Test func freshInstallPreparationFollowsOwnershipSafeOrdering() async {
        let system = DatabaseBrokerProcessTestSystem { runtime in
            runtime.finish(reason: .requested)
        }

        let exitCode = await DatabaseBrokerProcessRunner(
            dependencies: system.dependencies()
        ).run()

        #expect(exitCode == EXIT_SUCCESS)
        #expect(system.eventLog.events.contains("lifecycle-request"))
        let events = system.eventLog.events
        #expect(events.first == "umask")
        expect(
            "app-directories-make",
            before: "paths-make",
            in: events)
        expect("paths-make", before: "runtime-make", in: events)
        expect("runtime-make", before: "lifecycle-activate", in: events)
        expect(
            "lifecycle-activate",
            before: "app-directories-prepare",
            in: events)
        expect(
            "app-directories-prepare",
            before: "paths-prepare",
            in: events)
        expect("paths-prepare", before: "runtime-start", in: events)
        expect(
            "runtime-stopped-requested",
            before: "lifecycle-disarm",
            in: events)
        expect(
            "lifecycle-disarm",
            before: "lifecycle-cleanup",
            in: events)
    }

    @Test func signalDuringPreparationPreventsRuntimeStartup() async {
        let system = DatabaseBrokerProcessTestSystem { _ in
            Issue.record("runtime startup should not be reached")
        }
        let dependencies = system.dependencies(
            prepareAppDirectories: {
                system.lifecycle.signal(SIGTERM)
            })

        let exitCode = await DatabaseBrokerProcessRunner(
            dependencies: dependencies
        ).run()

        #expect(exitCode == EXIT_SUCCESS)
        let events = system.eventLog.events
        #expect(events.contains("lifecycle-signal-\(SIGTERM)"))
        #expect(!events.contains("paths-prepare"))
        #expect(!events.contains("runtime-start"))
        expect(
            "runtime-stopped-requested",
            before: "lifecycle-disarm",
            in: events)
    }

    @Test func signalDuringRuntimeStartStopsWithoutAStartupFailure() async {
        let startGate = DatabaseBrokerProcessTestGate()
        let system = DatabaseBrokerProcessTestSystem { _ in
            await startGate.wait()
        }
        let runTask = Task {
            await DatabaseBrokerProcessRunner(
                dependencies: system.dependencies()
            ).run()
        }
        await system.eventLog.wait(for: "runtime-start")

        system.lifecycle.signal(SIGINT)
        await startGate.open()
        let exitCode = await runTask.value

        #expect(exitCode == EXIT_SUCCESS)
        let events = system.eventLog.events
        #expect(events.contains("lifecycle-signal-\(SIGINT)"))
        #expect(events.contains("runtime-stopped-requested"))
        #expect(!events.contains("runtime-stopped-startup-failure"))
    }

    @Test func stampedeLoserExitsSuccessfully() async {
        let system = DatabaseBrokerProcessTestSystem { runtime in
            runtime.finish(reason: .startupFailure)
            throw DatabaseBrokerSocketError.listenerAlreadyRunning
        }

        let exitCode = await DatabaseBrokerProcessRunner(
            dependencies: system.dependencies()
        ).run()

        #expect(exitCode == EXIT_SUCCESS)
        #expect(system.eventLog.events.contains("runtime-stopped-startup-failure"))
    }

    @Test func peerVersionMismatchExitsSuccessfully() async {
        let system = DatabaseBrokerProcessTestSystem { runtime in
            runtime.finish(reason: .peerVersionMismatch)
        }

        let exitCode = await DatabaseBrokerProcessRunner(
            dependencies: system.dependencies()
        ).run()

        #expect(exitCode == EXIT_SUCCESS)
    }

    @Test func externalRequestedShutdownExitsSuccessfully() async {
        let startGate = DatabaseBrokerProcessTestGate()
        let system = DatabaseBrokerProcessTestSystem { _ in
            await startGate.wait()
        }
        let runTask = Task {
            await DatabaseBrokerProcessRunner(
                dependencies: system.dependencies()
            ).run()
        }
        await system.eventLog.wait(for: "runtime-start")

        system.lifecycle.request()
        await startGate.open()
        let exitCode = await runTask.value

        #expect(exitCode == EXIT_SUCCESS)
        #expect(system.eventLog.events.contains("lifecycle-external-request"))
    }

    @Test func signalWinsWhenPreparationAlsoFails() async {
        let system = DatabaseBrokerProcessTestSystem { _ in
            Issue.record("runtime startup should not be reached")
        }

        let exitCode = await DatabaseBrokerProcessRunner(
            dependencies: system.dependencies(
                preparePaths: {
                    system.lifecycle.signal(SIGTERM)
                    throw DatabaseBrokerProcessTestError.paths
                })
        ).run()

        #expect(exitCode == EXIT_SUCCESS)
        let events = system.eventLog.events
        #expect(events.contains("lifecycle-signal-\(SIGTERM)"))
        #expect(!events.contains("runtime-start"))
        expect(
            "runtime-stopped-requested",
            before: "lifecycle-disarm",
            in: events)
        expect(
            "lifecycle-disarm",
            before: "lifecycle-cleanup",
            in: events)
    }

    @Test func acceptFailureExitsWithFailureAfterCleanup() async {
        let system = DatabaseBrokerProcessTestSystem { runtime in
            runtime.finish(reason: .acceptFailure)
        }

        let exitCode = await DatabaseBrokerProcessRunner(
            dependencies: system.dependencies()
        ).run()

        #expect(exitCode == EXIT_FAILURE)
        let events = system.eventLog.events
        #expect(events.contains("lifecycle-request"))
        expect(
            "runtime-stopped-accept-failure",
            before: "lifecycle-disarm",
            in: events)
        expect(
            "lifecycle-disarm",
            before: "lifecycle-cleanup",
            in: events)
    }

    @Test func startupFailureExitsWithFailure() async {
        let system = DatabaseBrokerProcessTestSystem { runtime in
            runtime.finish(reason: .startupFailure)
            throw DatabaseBrokerProcessTestError.startup
        }

        let exitCode = await DatabaseBrokerProcessRunner(
            dependencies: system.dependencies()
        ).run()

        #expect(exitCode == EXIT_FAILURE)
    }

    @Test func stoppedRuntimeWithoutAReasonExitsWithFailure() async {
        let system = DatabaseBrokerProcessTestSystem { runtime in
            runtime.finishWithoutReason()
        }

        let exitCode = await DatabaseBrokerProcessRunner(
            dependencies: system.dependencies()
        ).run()

        #expect(exitCode == EXIT_FAILURE)
        #expect(system.eventLog.events.contains("runtime-stopped-without-reason"))
    }

    @Test func appDirectoryPreparationFailureExitsWithFailure() async {
        let system = DatabaseBrokerProcessTestSystem { _ in
            Issue.record("runtime startup should not be reached")
        }

        let exitCode = await DatabaseBrokerProcessRunner(
            dependencies: system.dependencies(
                prepareAppDirectories: {
                    throw DatabaseBrokerProcessTestError.appDirectories
                })
        ).run()

        #expect(exitCode == EXIT_FAILURE)
        let events = system.eventLog.events
        #expect(!events.contains("paths-prepare"))
        #expect(!events.contains("runtime-start"))
        expect(
            "runtime-stopped-requested",
            before: "lifecycle-disarm",
            in: events)
    }

    @Test func brokerPathPreparationFailureExitsWithFailure() async {
        let system = DatabaseBrokerProcessTestSystem { _ in
            Issue.record("runtime startup should not be reached")
        }

        let exitCode = await DatabaseBrokerProcessRunner(
            dependencies: system.dependencies(
                preparePaths: {
                    throw DatabaseBrokerProcessTestError.paths
                })
        ).run()

        #expect(exitCode == EXIT_FAILURE)
        let events = system.eventLog.events
        #expect(events.contains("app-directories-prepare"))
        #expect(!events.contains("runtime-start"))
        expect(
            "runtime-stopped-requested",
            before: "lifecycle-disarm",
            in: events)
    }

    @Test func lifecycleActivationFailureExitsWithFailure() async {
        let system = DatabaseBrokerProcessTestSystem { _ in
            Issue.record("runtime startup should not be reached")
        }

        let exitCode = await DatabaseBrokerProcessRunner(
            dependencies: system.dependencies(lifecycleError: .lifecycle)
        ).run()

        #expect(exitCode == EXIT_FAILURE)
        let events = system.eventLog.events
        #expect(!events.contains("app-directories-prepare"))
        #expect(!events.contains("runtime-start"))
        #expect(events.contains("runtime-stopped-requested"))
        #expect(!events.contains("lifecycle-disarm"))
        #expect(!events.contains("lifecycle-cleanup"))
    }

    private func expect(
        _ earlier: String,
        before later: String,
        in events: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let earlierIndex = events.firstIndex(of: earlier)
        let laterIndex = events.firstIndex(of: later)
        #expect(
            earlierIndex != nil && laterIndex != nil && earlierIndex! < laterIndex!,
            "expected \(earlier) before \(later), got \(events)",
            sourceLocation: sourceLocation)
    }
}
