import Dispatch
import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerRuntimeTestError: Error {
    case fixtureFailure
}

private final class DatabaseBrokerRuntimeTestLockedValue<Value>: @unchecked Sendable {
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

private final class DatabaseBrokerRuntimeTestEventLog: @unchecked Sendable {
    private struct State {
        var events: [String] = []
        var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    }

    private let state = DatabaseBrokerRuntimeTestLockedValue(State())

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

private final class DatabaseBrokerRuntimeTestConnection: @unchecked Sendable {
    let id: UUID
    private let eventLog: DatabaseBrokerRuntimeTestEventLog
    private let isClosed = DatabaseBrokerRuntimeTestLockedValue(false)

    init(
        id: UUID = UUID(),
        eventLog: DatabaseBrokerRuntimeTestEventLog
    ) {
        self.id = id
        self.eventLog = eventLog
    }

    var closeEvent: String {
        "connection-closed-\(id.uuidString)"
    }

    var closeCount: Int {
        isClosed.value ? 1 : 0
    }

    func runtimeConnection() -> DatabaseBrokerRuntimeConnection {
        DatabaseBrokerRuntimeConnection(
            id: id,
            serveHealth: { _, _ in
                throw DatabaseBrokerRuntimeTestError.fixtureFailure
            },
            close: {
                let shouldRecord = self.isClosed.update { isClosed in
                    guard !isClosed else { return false }
                    isClosed = true
                    return true
                }
                if shouldRecord {
                    self.eventLog.append(self.closeEvent)
                }
            })
    }
}

private final class DatabaseBrokerRuntimeTestListener: @unchecked Sendable {
    private struct State {
        var queuedConnections: [DatabaseBrokerRuntimeTestConnection]
        var generatedConnectionLimit: Int?
        var acceptCount = 0
        var acceptWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        var throwsOnAccept: Bool
        var isClosed = false
    }

    private let eventLog: DatabaseBrokerRuntimeTestEventLog
    private let state: DatabaseBrokerRuntimeTestLockedValue<State>

    init(
        connections: [DatabaseBrokerRuntimeTestConnection] = [],
        generatedConnectionLimit: Int? = nil,
        throwsOnAccept: Bool = false,
        eventLog: DatabaseBrokerRuntimeTestEventLog
    ) {
        self.eventLog = eventLog
        state = DatabaseBrokerRuntimeTestLockedValue(
            State(
                queuedConnections: connections,
                generatedConnectionLimit: generatedConnectionLimit,
                throwsOnAccept: throwsOnAccept))
    }

    var acceptCount: Int {
        state.value.acceptCount
    }

    var closeCount: Int {
        state.value.isClosed ? 1 : 0
    }

    func runtimeListener() -> DatabaseBrokerRuntimeListener {
        DatabaseBrokerRuntimeListener(
            socketDescriptor: { 91 },
            accept: {
                try self.accept()
            },
            close: {
                let shouldRecord = self.state.update { state in
                    guard !state.isClosed else { return false }
                    state.isClosed = true
                    return true
                }
                if shouldRecord {
                    self.eventLog.append("listener-closed")
                }
            })
    }

    func waitForAcceptCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.update { state in
                if state.acceptCount >= target {
                    return true
                }
                state.acceptWaiters.append((target, continuation))
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func accept() throws -> DatabaseBrokerRuntimeConnection? {
        let outcome = state.update { state -> DatabaseBrokerRuntimeTestAcceptOutcome in
            if state.throwsOnAccept {
                state.throwsOnAccept = false
                return .failure
            }
            let connection: DatabaseBrokerRuntimeTestConnection
            if !state.queuedConnections.isEmpty {
                connection = state.queuedConnections.removeFirst()
            } else if let limit = state.generatedConnectionLimit,
                state.acceptCount < limit
            {
                connection = DatabaseBrokerRuntimeTestConnection(
                    eventLog: eventLog)
            } else {
                return .empty
            }
            state.acceptCount += 1
            let readyWaiters = state.acceptWaiters.filter {
                state.acceptCount >= $0.0
            }
            state.acceptWaiters.removeAll {
                state.acceptCount >= $0.0
            }
            return .connection(connection, readyWaiters.map(\.1))
        }
        switch outcome {
        case .connection(let connection, let waiters):
            for waiter in waiters {
                waiter.resume()
            }
            return connection.runtimeConnection()
        case .empty:
            return nil
        case .failure:
            throw DatabaseBrokerRuntimeTestError.fixtureFailure
        }
    }
}

private enum DatabaseBrokerRuntimeTestAcceptOutcome {
    case connection(
        DatabaseBrokerRuntimeTestConnection,
        [CheckedContinuation<Void, Never>]
    )
    case empty
    case failure
}

private final class DatabaseBrokerRuntimeTestAcceptSource: @unchecked Sendable {
    private struct State {
        var onReadable: (@Sendable () -> Void)?
        var isActivated = false
        var holdsCancellation: Bool
        var cancellationWasReleased = false
        var cancellationWaiter: CheckedContinuation<Void, Never>?
    }

    private let eventLog: DatabaseBrokerRuntimeTestEventLog
    private let state: DatabaseBrokerRuntimeTestLockedValue<State>

    init(
        holdsCancellation: Bool = false,
        eventLog: DatabaseBrokerRuntimeTestEventLog
    ) {
        self.eventLog = eventLog
        state = DatabaseBrokerRuntimeTestLockedValue(
            State(holdsCancellation: holdsCancellation))
    }

    var isActivated: Bool {
        state.value.isActivated
    }

    func runtimeSource(
        onReadable: @escaping @Sendable () -> Void
    ) -> DatabaseBrokerRuntimeAcceptSource {
        state.update { state in
            state.onReadable = onReadable
        }
        return DatabaseBrokerRuntimeAcceptSource(
            activate: {
                self.state.update { state in
                    state.isActivated = true
                }
                self.eventLog.append("source-activated")
            },
            cancelAndWait: {
                self.eventLog.append("source-cancellation-started")
                await self.waitForCancellationRelease()
                self.eventLog.append("source-cancellation-completed")
            })
    }

    func trigger(count: Int = 1) {
        let onReadable = state.value.onReadable
        for _ in 0..<count {
            onReadable?()
        }
    }

    func releaseCancellation() {
        let waiter = state.update { state in
            state.cancellationWasReleased = true
            let waiter = state.cancellationWaiter
            state.cancellationWaiter = nil
            return waiter
        }
        waiter?.resume()
    }

    private func waitForCancellationRelease() async {
        guard state.value.holdsCancellation else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = state.update { state in
                if state.cancellationWasReleased {
                    return true
                }
                state.cancellationWaiter = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private actor DatabaseBrokerRuntimeTestBlockingTransport {
    private struct EntryWaiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let completionResult: DatabaseBrokerRuntimeClientResult
    private var enteredConnectionIDs: [UUID] = []
    private var responses: [DatabaseBrokerHealthResponse] = []
    private var pending: [UUID: CheckedContinuation<DatabaseBrokerRuntimeClientResult, Never>] =
        [:]
    private var entryWaiters: [EntryWaiter] = []

    init(completionResult: DatabaseBrokerRuntimeClientResult = .unexpectedFailure) {
        self.completionResult = completionResult
    }

    var enteredCount: Int {
        enteredConnectionIDs.count
    }

    func serve(
        connection: DatabaseBrokerRuntimeConnection,
        response: DatabaseBrokerRuntimeHealthResponseProvider
    ) async -> DatabaseBrokerRuntimeClientResult {
        enteredConnectionIDs.append(connection.id)
        responses.append(response(DatabaseBrokerHealthRequest()))
        resumeSatisfiedEntryWaiters()
        let connectionID = connection.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: completionResult)
                } else {
                    pending[connectionID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.complete(connectionID: connectionID)
            }
        }
    }

    func waitForEnteredCount(_ target: Int) async {
        if enteredConnectionIDs.count >= target {
            return
        }
        await withCheckedContinuation { continuation in
            entryWaiters.append(
                EntryWaiter(
                    target: target,
                    continuation: continuation))
        }
    }

    func capturedResponses() -> [DatabaseBrokerHealthResponse] {
        responses
    }

    func completeAll() {
        let continuations = pending.values
        pending.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume(returning: completionResult)
        }
    }

    private func complete(connectionID: UUID) {
        pending.removeValue(forKey: connectionID)?.resume(
            returning: completionResult)
    }

    private func resumeSatisfiedEntryWaiters() {
        let readyWaiters = entryWaiters.filter {
            enteredConnectionIDs.count >= $0.target
        }
        entryWaiters.removeAll {
            enteredConnectionIDs.count >= $0.target
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }
}

private final class DatabaseBrokerRuntimeTestShutdownRecorder: @unchecked Sendable {
    private let storedReasons = DatabaseBrokerRuntimeTestLockedValue(
        [DatabaseBrokerRuntimeShutdownReason]())

    var reasons: [DatabaseBrokerRuntimeShutdownReason] {
        storedReasons.value
    }

    func record(_ reason: DatabaseBrokerRuntimeShutdownReason) {
        storedReasons.update { reasons in
            reasons.append(reason)
        }
    }
}

private final class DatabaseBrokerRuntimeTestStartupGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let eventLog: DatabaseBrokerRuntimeTestEventLog

    init(eventLog: DatabaseBrokerRuntimeTestEventLog) {
        self.eventLog = eventLog
    }

    func wait() {
        eventLog.append("startup-blocked")
        semaphore.wait()
    }

    func release() {
        semaphore.signal()
    }
}

private func databaseBrokerRuntimeTestDependencies(
    listener: DatabaseBrokerRuntimeTestListener,
    source: DatabaseBrokerRuntimeTestAcceptSource,
    transport: DatabaseBrokerRuntimeTransport,
    shutdownRecorder: DatabaseBrokerRuntimeTestShutdownRecorder
) -> DatabaseBrokerRuntimeDependencies {
    DatabaseBrokerRuntimeDependencies(
        makeTransport: { transport },
        makeListener: { _ in listener.runtimeListener() },
        makeAcceptSource: { _, onReadable in
            source.runtimeSource(onReadable: onReadable)
        },
        observeShutdownRequest: { reason in
            shutdownRecorder.record(reason)
        })
}

private func databaseBrokerRuntimeAuthenticationFailure(
    _ error: DatabaseBrokerPeerAuthenticationError
) -> DatabaseBrokerRuntimeClientResult {
    .failed(
        DatabaseBrokerHealthTransportError(
            failure: .authenticationFailed(error),
            bytesWritten: 0))
}

@Suite
struct DatabaseBrokerRuntimeTests {
    @Test
    func readinessUsesOneStableInstanceIdentifier() async throws {
        let eventLog = DatabaseBrokerRuntimeTestEventLog()
        let connections = (0..<2).map { _ in
            DatabaseBrokerRuntimeTestConnection(eventLog: eventLog)
        }
        let listener = DatabaseBrokerRuntimeTestListener(
            connections: connections,
            eventLog: eventLog)
        let source = DatabaseBrokerRuntimeTestAcceptSource(eventLog: eventLog)
        let transportController = DatabaseBrokerRuntimeTestBlockingTransport()
        let transport = DatabaseBrokerRuntimeTransport { connection, response in
            await transportController.serve(
                connection: connection,
                response: response)
        }
        let shutdownRecorder = DatabaseBrokerRuntimeTestShutdownRecorder()
        let instanceID = UUID(
            uuidString: "42C6B72C-A665-4DF5-ACF2-55703F3D440B")!
        let runtime = DatabaseBrokerRuntime(
            brokerInstanceID: instanceID,
            dependencies: databaseBrokerRuntimeTestDependencies(
                listener: listener,
                source: source,
                transport: transport,
                shutdownRecorder: shutdownRecorder))

        try await runtime.start()
        let readySnapshot = await runtime.snapshot()
        #expect(readySnapshot.phase == .ready)
        #expect(readySnapshot.brokerInstanceID == instanceID)
        #expect(readySnapshot.isReady)
        #expect(source.isActivated)

        source.trigger()
        await transportController.waitForEnteredCount(2)
        let responses = await transportController.capturedResponses()
        #expect(responses.count == 2)
        #expect(responses.allSatisfy { $0.brokerInstanceID == instanceID })
        #expect(responses.allSatisfy { $0.isReady })

        await transportController.completeAll()
        await runtime.shutdown()
        let stoppedSnapshot = await runtime.snapshot()
        #expect(stoppedSnapshot.phase == .stopped)
        #expect(!stoppedSnapshot.isReady)
        #expect(stoppedSnapshot.brokerInstanceID == instanceID)
        #expect(shutdownRecorder.reasons == [.requested])
    }

    @Test
    func overloadClosesBeforeTransportAdmission() async throws {
        let eventLog = DatabaseBrokerRuntimeTestEventLog()
        let connections = (0...DatabaseBrokerRuntime.maximumActiveClients).map { _ in
            DatabaseBrokerRuntimeTestConnection(eventLog: eventLog)
        }
        let listener = DatabaseBrokerRuntimeTestListener(
            connections: connections,
            eventLog: eventLog)
        let source = DatabaseBrokerRuntimeTestAcceptSource(eventLog: eventLog)
        let transportController = DatabaseBrokerRuntimeTestBlockingTransport()
        let transport = DatabaseBrokerRuntimeTransport { connection, response in
            await transportController.serve(
                connection: connection,
                response: response)
        }
        let shutdownRecorder = DatabaseBrokerRuntimeTestShutdownRecorder()
        let runtime = DatabaseBrokerRuntime(
            dependencies: databaseBrokerRuntimeTestDependencies(
                listener: listener,
                source: source,
                transport: transport,
                shutdownRecorder: shutdownRecorder))

        try await runtime.start()
        source.trigger()
        await transportController.waitForEnteredCount(
            DatabaseBrokerRuntime.maximumActiveClients)
        await eventLog.wait(for: connections.last!.closeEvent)

        #expect(await transportController.enteredCount == 32)
        #expect(connections.dropLast().allSatisfy { $0.closeCount == 0 })
        #expect(connections.last?.closeCount == 1)
        #expect(await runtime.snapshot().activeClientCount == 32)

        await transportController.completeAll()
        await runtime.shutdown()
        #expect(connections.allSatisfy { $0.closeCount == 1 })
    }

    @Test
    func uniqueIdentifierMismatchRequestsShutdownOnce() async throws {
        let eventLog = DatabaseBrokerRuntimeTestEventLog()
        let connections = (0..<2).map { _ in
            DatabaseBrokerRuntimeTestConnection(eventLog: eventLog)
        }
        let listener = DatabaseBrokerRuntimeTestListener(
            connections: connections,
            eventLog: eventLog)
        let source = DatabaseBrokerRuntimeTestAcceptSource(eventLog: eventLog)
        let transport = DatabaseBrokerRuntimeTransport { _, _ in
            databaseBrokerRuntimeAuthenticationFailure(.uniqueIdentifierMismatch)
        }
        let shutdownRecorder = DatabaseBrokerRuntimeTestShutdownRecorder()
        let runtime = DatabaseBrokerRuntime(
            dependencies: databaseBrokerRuntimeTestDependencies(
                listener: listener,
                source: source,
                transport: transport,
                shutdownRecorder: shutdownRecorder))

        try await runtime.start()
        source.trigger()
        await runtime.waitUntilStopped()

        let snapshot = await runtime.snapshot()
        #expect(snapshot.phase == .stopped)
        #expect(snapshot.shutdownReason == .peerVersionMismatch)
        #expect(snapshot.shutdownRequestCount == 1)
        #expect(shutdownRecorder.reasons == [.peerVersionMismatch])
        #expect(connections.allSatisfy { $0.closeCount == 1 })
        #expect(listener.closeCount == 1)
    }

    @Test
    func otherAuthenticationFailureClosesOnlyItsConnection() async throws {
        let eventLog = DatabaseBrokerRuntimeTestEventLog()
        let connection = DatabaseBrokerRuntimeTestConnection(eventLog: eventLog)
        let listener = DatabaseBrokerRuntimeTestListener(
            connections: [connection],
            eventLog: eventLog)
        let source = DatabaseBrokerRuntimeTestAcceptSource(eventLog: eventLog)
        let transport = DatabaseBrokerRuntimeTransport { _, _ in
            databaseBrokerRuntimeAuthenticationFailure(.peerCodeInvalid)
        }
        let shutdownRecorder = DatabaseBrokerRuntimeTestShutdownRecorder()
        let runtime = DatabaseBrokerRuntime(
            dependencies: databaseBrokerRuntimeTestDependencies(
                listener: listener,
                source: source,
                transport: transport,
                shutdownRecorder: shutdownRecorder))

        try await runtime.start()
        source.trigger()
        await eventLog.wait(for: connection.closeEvent)

        let snapshot = await runtime.snapshot()
        #expect(snapshot.phase == .ready)
        #expect(snapshot.shutdownReason == nil)
        #expect(snapshot.shutdownRequestCount == 0)
        #expect(shutdownRecorder.reasons.isEmpty)
        #expect(listener.closeCount == 0)

        await runtime.shutdown()
    }

    @Test
    func acceptFailureRequestsShutdown() async throws {
        let eventLog = DatabaseBrokerRuntimeTestEventLog()
        let listener = DatabaseBrokerRuntimeTestListener(
            throwsOnAccept: true,
            eventLog: eventLog)
        let source = DatabaseBrokerRuntimeTestAcceptSource(eventLog: eventLog)
        let transport = DatabaseBrokerRuntimeTransport { _, _ in
            .unexpectedFailure
        }
        let shutdownRecorder = DatabaseBrokerRuntimeTestShutdownRecorder()
        let runtime = DatabaseBrokerRuntime(
            dependencies: databaseBrokerRuntimeTestDependencies(
                listener: listener,
                source: source,
                transport: transport,
                shutdownRecorder: shutdownRecorder))

        try await runtime.start()
        source.trigger()
        await runtime.waitUntilStopped()

        let snapshot = await runtime.snapshot()
        #expect(snapshot.phase == .stopped)
        #expect(snapshot.shutdownReason == .acceptFailure)
        #expect(snapshot.shutdownRequestCount == 1)
        #expect(shutdownRecorder.reasons == [.acceptFailure])
        #expect(listener.closeCount == 1)
    }

    @Test
    func repeatedShutdownPreservesOrderedDrain() async throws {
        let eventLog = DatabaseBrokerRuntimeTestEventLog()
        let connection = DatabaseBrokerRuntimeTestConnection(eventLog: eventLog)
        let listener = DatabaseBrokerRuntimeTestListener(
            connections: [connection],
            eventLog: eventLog)
        let source = DatabaseBrokerRuntimeTestAcceptSource(
            holdsCancellation: true,
            eventLog: eventLog)
        let transportController = DatabaseBrokerRuntimeTestBlockingTransport()
        let transport = DatabaseBrokerRuntimeTransport { connection, response in
            await transportController.serve(
                connection: connection,
                response: response)
        }
        let shutdownRecorder = DatabaseBrokerRuntimeTestShutdownRecorder()
        let runtime = DatabaseBrokerRuntime(
            dependencies: databaseBrokerRuntimeTestDependencies(
                listener: listener,
                source: source,
                transport: transport,
                shutdownRecorder: shutdownRecorder))

        try await runtime.start()
        source.trigger()
        await transportController.waitForEnteredCount(1)
        let firstShutdown = Task {
            await runtime.shutdown()
        }
        let secondShutdown = Task {
            await runtime.shutdown()
        }
        await eventLog.wait(for: "source-cancellation-started")

        let drainingSnapshot = await runtime.snapshot()
        #expect(drainingSnapshot.phase == .draining)
        #expect(!drainingSnapshot.isReady)
        #expect(connection.closeCount == 0)
        #expect(listener.closeCount == 0)

        source.releaseCancellation()
        await firstShutdown.value
        await secondShutdown.value

        let events = eventLog.events
        let sourceCompletedIndex = try #require(
            events.firstIndex(of: "source-cancellation-completed"))
        let connectionClosedIndex = try #require(
            events.firstIndex(of: connection.closeEvent))
        let listenerClosedIndex = try #require(
            events.firstIndex(of: "listener-closed"))
        #expect(sourceCompletedIndex < connectionClosedIndex)
        #expect(connectionClosedIndex < listenerClosedIndex)
        #expect(shutdownRecorder.reasons == [.requested])
        #expect(await runtime.snapshot().shutdownRequestCount == 1)
    }

    @Test
    func readableEventsAreSingleFlight() {
        let scheduledCount = DatabaseBrokerRuntimeTestLockedValue(0)
        let gate = DatabaseBrokerRuntimeReadableGate {
            scheduledCount.update { $0 += 1 }
        }

        for _ in 0..<100 {
            gate.readable()
        }
        #expect(scheduledCount.value == 1)

        gate.drainCompleted(shouldReschedule: false)
        #expect(scheduledCount.value == 2)
        for _ in 0..<100 {
            gate.readable()
        }
        #expect(scheduledCount.value == 2)

        gate.drainCompleted(shouldReschedule: false)
        #expect(scheduledCount.value == 3)
        gate.drainCompleted(shouldReschedule: false)
        #expect(scheduledCount.value == 3)
    }

    @Test
    func connectionFloodCannotStarveShutdown() async throws {
        let eventLog = DatabaseBrokerRuntimeTestEventLog()
        let generatedConnectionLimit = 1_000_000
        let listener = DatabaseBrokerRuntimeTestListener(
            generatedConnectionLimit: generatedConnectionLimit,
            eventLog: eventLog)
        let source = DatabaseBrokerRuntimeTestAcceptSource(eventLog: eventLog)
        let transport = DatabaseBrokerRuntimeTransport { _, _ in
            .unexpectedFailure
        }
        let shutdownRecorder = DatabaseBrokerRuntimeTestShutdownRecorder()
        let runtime = DatabaseBrokerRuntime(
            dependencies: databaseBrokerRuntimeTestDependencies(
                listener: listener,
                source: source,
                transport: transport,
                shutdownRecorder: shutdownRecorder))

        try await runtime.start()
        source.trigger(count: 1_000)
        await listener.waitForAcceptCount(
            DatabaseBrokerRuntime.maximumAcceptBatchSize)
        await runtime.shutdown()

        #expect(listener.acceptCount < generatedConnectionLimit)
        #expect(listener.closeCount == 1)
        #expect(shutdownRecorder.reasons == [.requested])
        #expect(await runtime.snapshot().phase == .stopped)
    }

    @Test
    func blockingStartupWorkDoesNotOccupyTheActor() async throws {
        let eventLog = DatabaseBrokerRuntimeTestEventLog()
        let startupGate = DatabaseBrokerRuntimeTestStartupGate(eventLog: eventLog)
        let listener = DatabaseBrokerRuntimeTestListener(eventLog: eventLog)
        let source = DatabaseBrokerRuntimeTestAcceptSource(eventLog: eventLog)
        let shutdownRecorder = DatabaseBrokerRuntimeTestShutdownRecorder()
        let transport = DatabaseBrokerRuntimeTransport { _, _ in
            .unexpectedFailure
        }
        let dependencies = DatabaseBrokerRuntimeDependencies(
            makeTransport: {
                startupGate.wait()
                return transport
            },
            makeListener: { _ in listener.runtimeListener() },
            makeAcceptSource: { _, onReadable in
                source.runtimeSource(onReadable: onReadable)
            },
            observeShutdownRequest: { reason in
                shutdownRecorder.record(reason)
            })
        let runtime = DatabaseBrokerRuntime(dependencies: dependencies)
        let startTask = Task {
            try await runtime.start()
        }

        await eventLog.wait(for: "startup-blocked")
        let snapshot = await runtime.snapshot()
        #expect(snapshot.phase == .starting)
        #expect(!snapshot.isReady)

        startupGate.release()
        try await startTask.value
        #expect(await runtime.snapshot().phase == .ready)
        await runtime.shutdown()
    }

    @Test
    func startupFailureClosesCreatedListener() async throws {
        let eventLog = DatabaseBrokerRuntimeTestEventLog()
        let shutdownRecorder = DatabaseBrokerRuntimeTestShutdownRecorder()
        let listenerClosed = DatabaseBrokerRuntimeTestLockedValue(false)
        let dependencies = DatabaseBrokerRuntimeDependencies(
            makeTransport: {
                DatabaseBrokerRuntimeTransport { _, _ in
                    .unexpectedFailure
                }
            },
            makeListener: { _ in
                DatabaseBrokerRuntimeListener(
                    socketDescriptor: {
                        throw DatabaseBrokerRuntimeTestError.fixtureFailure
                    },
                    accept: { nil },
                    close: {
                        listenerClosed.update { $0 = true }
                        eventLog.append("listener-closed")
                    })
            },
            makeAcceptSource: { _, _ in
                throw DatabaseBrokerRuntimeTestError.fixtureFailure
            },
            observeShutdownRequest: { reason in
                shutdownRecorder.record(reason)
            })
        let runtime = DatabaseBrokerRuntime(dependencies: dependencies)

        await #expect(throws: DatabaseBrokerRuntimeTestError.self) {
            try await runtime.start()
        }

        let snapshot = await runtime.snapshot()
        #expect(listenerClosed.value)
        #expect(snapshot.phase == .stopped)
        #expect(snapshot.shutdownReason == .startupFailure)
        #expect(snapshot.shutdownRequestCount == 1)
        #expect(shutdownRecorder.reasons == [.startupFailure])
    }
}
