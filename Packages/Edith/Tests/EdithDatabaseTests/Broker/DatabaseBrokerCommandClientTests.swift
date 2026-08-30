import Dispatch
import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerCommandClientTestError: Error {
    case injected(String)
    case unsupportedRequest
}

private enum DatabaseBrokerCommandClientTestEvent: Equatable {
    case readiness
    case connection
    case request
    case close
}

private final class DatabaseBrokerCommandClientTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DatabaseBrokerCommandClientTestEvent] = []
    private var connectionCount = 0
    private var requestCount = 0
    private var closeCount = 0
    private var observedMainThread = false
    private var observedOperationIDs: [DatabaseOperationID?] = []
    private var observedRequestIDs: [UUID] = []
    private var observedConnectionDeadlines: [UInt64] = []
    private var observedRequestDeadlines: [UInt64] = []

    func record(_ event: DatabaseBrokerCommandClientTestEvent) {
        lock.withLock {
            events.append(event)
            switch event {
            case .readiness:
                break
            case .connection:
                connectionCount += 1
            case .request:
                requestCount += 1
            case .close:
                closeCount += 1
            }
        }
    }

    func recordConnection(deadlineNanoseconds: UInt64) {
        lock.withLock {
            events.append(.connection)
            connectionCount += 1
            observedConnectionDeadlines.append(deadlineNanoseconds)
        }
    }

    func recordRequest(
        _ request: DatabaseBrokerCommandRequest,
        requestID: UUID,
        isMainThread: Bool,
        deadlineNanoseconds: UInt64? = nil
    ) {
        lock.withLock {
            events.append(.request)
            requestCount += 1
            observedOperationIDs.append(request.operationID)
            observedRequestIDs.append(requestID)
            observedMainThread = observedMainThread || isMainThread
            if let deadlineNanoseconds {
                observedRequestDeadlines.append(deadlineNanoseconds)
            }
        }
    }

    func snapshot() -> (
        events: [DatabaseBrokerCommandClientTestEvent],
        connections: Int,
        requests: Int,
        closes: Int,
        observedMainThread: Bool,
        operationIDs: [DatabaseOperationID?],
        requestIDs: [UUID],
        connectionDeadlines: [UInt64],
        requestDeadlines: [UInt64]
    ) {
        lock.withLock {
            (
                events,
                connectionCount,
                requestCount,
                closeCount,
                observedMainThread,
                observedOperationIDs,
                observedRequestIDs,
                observedConnectionDeadlines,
                observedRequestDeadlines
            )
        }
    }
}

private final class DatabaseBrokerCommandClientTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func now() -> UInt64 {
        lock.withLock { value }
    }

    func set(_ value: UInt64) {
        lock.withLock {
            self.value = value
        }
    }
}

private final class DatabaseBrokerCommandClientBlockingSocket: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var closeCount = 0
    private var closed = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    func waitThenFail<Response>(
        bytesWritten: Int
    ) throws -> Response {
        let waitingForEntry = lock.withLock {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waitingForEntry {
            waiter.resume()
        }
        releaseSemaphore.wait()
        throw DatabaseBrokerHealthTransportError(
            failure: .connectionClosed,
            bytesWritten: bytesWritten)
    }

    func close() {
        let waitingForClose = lock.withLock {
            closeCount += 1
            guard !closed else { return [CheckedContinuation<Void, Never>]() }
            closed = true
            let waiters = closeWaiters
            closeWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        releaseSemaphore.signal()
        for waiter in waitingForClose {
            waiter.resume()
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard !entered else { return true }
                entryWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard !closed else { return true }
                closeWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func closeCountValue() -> Int {
        lock.withLock { closeCount }
    }
}

private final class DatabaseBrokerCommandClientFactoryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndBlock() {
        let waitingForEntry = lock.withLock {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waitingForEntry {
            waiter.resume()
        }
        releaseSemaphore.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard !entered else { return true }
                entryWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class DatabaseBrokerCommandClientSocketRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [DatabaseOperationID: DatabaseBrokerCommandClientBlockingSocket] = [:]

    func register(
        _ socket: DatabaseBrokerCommandClientBlockingSocket,
        for operationID: DatabaseOperationID
    ) {
        lock.withLock {
            sockets[operationID] = socket
        }
    }

    func socket(
        for operationID: DatabaseOperationID
    ) -> DatabaseBrokerCommandClientBlockingSocket? {
        lock.withLock { sockets[operationID] }
    }
}

@Test @MainActor
func databaseBrokerCommandClientEnsuresReadinessAndRunsSocketIOOffMainActor() async throws {
    let recorder = DatabaseBrokerCommandClientTestRecorder()
    let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "453B75EF-C2B4-41BF-9101-A94027DA76A1")!)
    let requestID = UUID(uuidString: "E307B93A-E651-42CB-A172-E928DAAEE97D")!
    let request = DatabaseBrokerCommandRequest.operationGet(
        DatabaseOperationGetRequest(operationID: operationID))
    let client = DatabaseBrokerCommandClient(
        dependencies: DatabaseBrokerCommandClientDependencies(
            ensureReady: {
                recorder.record(.readiness)
            },
            makeRequestID: { requestID },
            makeConnection: { _ in
                recorder.record(.connection)
                return DatabaseBrokerCommandClientConnection(
                    request: { request, observedRequestID, _ in
                        recorder.recordRequest(
                            request,
                            requestID: observedRequestID,
                            isMainThread: Thread.isMainThread)
                        return try databaseBrokerCommandClientResponse(
                            for: request,
                            requestID: observedRequestID)
                    },
                    close: {
                        recorder.record(.close)
                    })
            }))
    let sender: any DatabaseBrokerCommandSending = client

    let response = try await sender.send(request)
    let snapshot = recorder.snapshot()

    #expect(response.operationGetResult?.payload?.operation == nil)
    #expect(snapshot.events == [.readiness, .connection, .request, .close])
    #expect(snapshot.connections == 1)
    #expect(snapshot.requests == 1)
    #expect(snapshot.closes == 1)
    #expect(!snapshot.observedMainThread)
    #expect(snapshot.operationIDs == [operationID])
    #expect(snapshot.requestIDs == [requestID])
}

@Test func databaseBrokerCommandClientPropagatesOneDeadlineComputedAfterReadiness() async throws {
    let recorder = DatabaseBrokerCommandClientTestRecorder()
    let clock = DatabaseBrokerCommandClientTestClock(10)
    let requestID = UUID(uuidString: "AD14776F-E4E9-4E49-A3C1-6EAAB2B98E97")!
    let request = DatabaseBrokerCommandRequest.connectionList(
        DatabaseConnectionListRequest())
    let client = DatabaseBrokerCommandClient(
        dependencies: DatabaseBrokerCommandClientDependencies(
            ensureReady: {
                recorder.record(.readiness)
                clock.set(1_000)
            },
            monotonicNanoseconds: { clock.now() },
            makeRequestID: { requestID },
            makeConnection: { deadlineNanoseconds in
                recorder.recordConnection(deadlineNanoseconds: deadlineNanoseconds)
                return DatabaseBrokerCommandClientConnection(
                    request: { request, observedRequestID, requestDeadlineNanoseconds in
                        recorder.recordRequest(
                            request,
                            requestID: observedRequestID,
                            isMainThread: Thread.isMainThread,
                            deadlineNanoseconds: requestDeadlineNanoseconds)
                        return try databaseBrokerCommandClientResponse(
                            for: request,
                            requestID: observedRequestID)
                    },
                    close: {
                        recorder.record(.close)
                    })
            }))

    let response = try await client.send(request)
    let expectedDeadline = 1_000 + DatabaseBrokerCommandClient.defaultTransportBudgetNanoseconds
    let snapshot = recorder.snapshot()

    #expect(response.connectionListResult?.payload?.connections == [])
    #expect(snapshot.events == [.readiness, .connection, .request, .close])
    #expect(snapshot.connectionDeadlines == [expectedDeadline])
    #expect(snapshot.requestDeadlines == [expectedDeadline])
    #expect(snapshot.requestIDs == [requestID])
}

@Test func databaseBrokerCommandClientDeadlineMathIsOverflowSafeAndCapsConnectTime() throws {
    #expect(DatabaseBrokerCommandClient.defaultTransportBudgetNanoseconds == 30_000_000_000)
    #expect(
        DatabaseBrokerCommandClient.deadline(
            startingAt: UInt64.max - 10,
            budget: 100) == UInt64.max)
    #expect(
        try DatabaseBrokerCommandClient.connectionTimeoutMilliseconds(
            deadlineNanoseconds: 1_500_001,
            nowNanoseconds: 1) == 2)
    #expect(
        try DatabaseBrokerCommandClient.connectionTimeoutMilliseconds(
            deadlineNanoseconds: 100_000_000_001,
            nowNanoseconds: 1)
            == DatabaseBrokerSocketConnection.maximumTimeoutMilliseconds)
    #expect(throws: DatabaseBrokerSocketError.connectionTimedOut) {
        try DatabaseBrokerCommandClient.connectionTimeoutMilliseconds(
            deadlineNanoseconds: 100,
            nowNanoseconds: 100)
    }
}

@Test func databaseBrokerCommandClientTotalDeadlineIncludesConnectionCreation() async {
    let recorder = DatabaseBrokerCommandClientTestRecorder()
    let clock = DatabaseBrokerCommandClientTestClock(100)
    let request = DatabaseBrokerCommandRequest.connectionList(
        DatabaseConnectionListRequest())
    let client = DatabaseBrokerCommandClient(
        dependencies: DatabaseBrokerCommandClientDependencies(
            ensureReady: {},
            monotonicNanoseconds: { clock.now() },
            transportBudgetNanoseconds: 50,
            makeConnection: { deadlineNanoseconds in
                recorder.recordConnection(deadlineNanoseconds: deadlineNanoseconds)
                clock.set(deadlineNanoseconds)
                return DatabaseBrokerCommandClientConnection(
                    request: { _, _, _ in
                        throw DatabaseBrokerCommandClientTestError.injected(
                            "request must not run")
                    },
                    close: {
                        recorder.record(.close)
                    })
            }))

    await #expect(throws: DatabaseBrokerCommandClientError.timedOut) {
        _ = try await client.send(request)
    }
    let snapshot = recorder.snapshot()
    #expect(snapshot.connectionDeadlines == [150])
    #expect(snapshot.requests == 0)
    #expect(snapshot.closes == 1)
}

@Test func databaseBrokerCommandClientClassifiesConnectTimeout() async {
    let request = DatabaseBrokerCommandRequest.connectionList(
        DatabaseConnectionListRequest())
    let client = DatabaseBrokerCommandClient(
        dependencies: DatabaseBrokerCommandClientDependencies(
            ensureReady: {},
            makeConnection: { _ in
                throw DatabaseBrokerSocketError.connectionTimedOut
            }))

    await #expect(throws: DatabaseBrokerCommandClientError.timedOut) {
        _ = try await client.send(request)
    }
}

@Test(
    arguments: [
        DatabaseBrokerHealthTransportFailure.authenticationTimedOut,
        DatabaseBrokerHealthTransportFailure.readTimedOut,
        DatabaseBrokerHealthTransportFailure.writeProgressTimedOut,
    ])
func databaseBrokerCommandClientClassifiesPreWriteTransportTimeout(
    _ failure: DatabaseBrokerHealthTransportFailure
) async {
    let client = databaseBrokerCommandClientFailingClient(
        recorder: DatabaseBrokerCommandClientTestRecorder(),
        error: DatabaseBrokerHealthTransportError(
            failure: failure,
            bytesWritten: 0))

    await #expect(throws: DatabaseBrokerCommandClientError.timedOut) {
        _ = try await client.send(
            .connectionList(DatabaseConnectionListRequest()))
    }
}

@Test(
    arguments: [
        DatabaseBrokerHealthTransportFailure.readTimedOut,
        DatabaseBrokerHealthTransportFailure.writeProgressTimedOut,
    ])
func databaseBrokerCommandClientKeepsPostWriteTimeoutOutcomeUnknown(
    _ failure: DatabaseBrokerHealthTransportFailure
) async {
    let client = databaseBrokerCommandClientFailingClient(
        recorder: DatabaseBrokerCommandClientTestRecorder(),
        error: DatabaseBrokerHealthTransportError(
            failure: failure,
            bytesWritten: 1))

    await #expect(throws: DatabaseBrokerCommandClientError.outcomeUnknown) {
        _ = try await client.send(
            .connectionList(DatabaseConnectionListRequest()))
    }
}

@Test func databaseBrokerCommandClientStopsBeforeConnectingWhenReadinessFails() async {
    let recorder = DatabaseBrokerCommandClientTestRecorder()
    let request = DatabaseBrokerCommandRequest.connectionList(
        DatabaseConnectionListRequest())
    let client = DatabaseBrokerCommandClient(
        dependencies: DatabaseBrokerCommandClientDependencies(
            ensureReady: {
                throw DatabaseBrokerCommandClientTestError.injected(
                    "private readiness detail")
            },
            makeConnection: { _ in
                recorder.record(.connection)
                throw DatabaseBrokerSocketError.unavailable
            }))

    do {
        _ = try await client.send(request)
        Issue.record("Expected readiness failure")
    } catch let error as DatabaseBrokerCommandClientError {
        #expect(error == .unavailable)
        #expect(!String(describing: error).contains("private readiness detail"))
    } catch {
        Issue.record("Unexpected error type")
    }
    #expect(recorder.snapshot().connections == 0)
}

@Test func databaseBrokerCommandClientDoesNotReplayProvenPreWriteFailure() async {
    let recorder = DatabaseBrokerCommandClientTestRecorder()
    let request = DatabaseBrokerCommandRequest.connectionList(
        DatabaseConnectionListRequest())
    let client = databaseBrokerCommandClientFailingClient(
        recorder: recorder,
        error: DatabaseBrokerHealthTransportError(
            failure: .connectionClosed,
            bytesWritten: 0))

    await #expect(throws: DatabaseBrokerCommandClientError.unavailable) {
        _ = try await client.send(request)
    }
    let snapshot = recorder.snapshot()
    #expect(snapshot.connections == 1)
    #expect(snapshot.requests == 1)
    #expect(snapshot.closes == 1)
}

@Test func databaseBrokerCommandClientNeverReplaysMutationApply() async {
    let recorder = DatabaseBrokerCommandClientTestRecorder()
    let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "EE775E11-7B4A-4CEE-901D-9027D7FA1677")!)
    let request = databaseBrokerCommandClientMutationApplyRequest(
        operationID: operationID)
    let client = databaseBrokerCommandClientFailingClient(
        recorder: recorder,
        error: DatabaseBrokerHealthTransportError(
            failure: .connectionClosed,
            bytesWritten: 0))

    await #expect(throws: DatabaseBrokerCommandClientError.unavailable) {
        _ = try await client.send(request)
    }
    let snapshot = recorder.snapshot()
    #expect(snapshot.connections == 1)
    #expect(snapshot.requests == 1)
    #expect(snapshot.closes == 1)
    #expect(snapshot.operationIDs == [operationID])
}

@Test func databaseBrokerCommandClientDoesNotReplayPostWriteFailure() async {
    let recorder = DatabaseBrokerCommandClientTestRecorder()
    let request = DatabaseBrokerCommandRequest.connectionList(
        DatabaseConnectionListRequest())
    let client = databaseBrokerCommandClientFailingClient(
        recorder: recorder,
        error: DatabaseBrokerCommandTransportError(
            failure: .invalidResponse,
            bytesWritten: 32))

    await #expect(throws: DatabaseBrokerCommandClientError.outcomeUnknown) {
        _ = try await client.send(request)
    }
    let snapshot = recorder.snapshot()
    #expect(snapshot.connections == 1)
    #expect(snapshot.requests == 1)
    #expect(snapshot.closes == 1)
}

@Test func databaseBrokerCommandClientSanitizesPeerAndRequestFailures() async {
    let peerRecorder = DatabaseBrokerCommandClientTestRecorder()
    let requestRecorder = DatabaseBrokerCommandClientTestRecorder()
    let request = DatabaseBrokerCommandRequest.connectionList(
        DatabaseConnectionListRequest())
    let peerClient = databaseBrokerCommandClientFailingClient(
        recorder: peerRecorder,
        error: DatabaseBrokerHealthTransportError(
            failure: .authenticationFailed(.invalidSocketDescriptor),
            bytesWritten: 0))
    let invalidClient = databaseBrokerCommandClientFailingClient(
        recorder: requestRecorder,
        error: DatabaseBrokerCommandTransportError(
            failure: .invalidRequest,
            bytesWritten: 0))

    await #expect(throws: DatabaseBrokerCommandClientError.unsafePeer) {
        _ = try await peerClient.send(request)
    }
    await #expect(throws: DatabaseBrokerCommandClientError.invalidRequest) {
        _ = try await invalidClient.send(request)
    }
}

@Test func databaseBrokerCommandClientCancellationClosesOnlyItsOwnSocket() async throws {
    let cancelledOperationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "D369C489-A1AC-418D-9848-BA119120BBF4")!)
    let completedOperationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "EECC02C0-C000-4C29-9F9C-7F269EC1B51A")!)
    let cancelledRequest = DatabaseBrokerCommandRequest.operationGet(
        DatabaseOperationGetRequest(operationID: cancelledOperationID))
    let completedRequest = DatabaseBrokerCommandRequest.operationGet(
        DatabaseOperationGetRequest(operationID: completedOperationID))
    let registry = DatabaseBrokerCommandClientSocketRegistry()
    let blocked = DatabaseBrokerCommandClientBlockingSocket()
    let client = DatabaseBrokerCommandClient(
        dependencies: DatabaseBrokerCommandClientDependencies(
            ensureReady: {},
            makeConnection: { _ in
                let socket = DatabaseBrokerCommandClientBlockingSocket()
                return DatabaseBrokerCommandClientConnection(
                    request: { request, requestID, _ in
                        guard let operationID = request.operationID else {
                            throw DatabaseBrokerCommandClientTestError.unsupportedRequest
                        }
                        registry.register(socket, for: operationID)
                        if operationID == cancelledOperationID {
                            return try blocked.waitThenFail(bytesWritten: 0)
                        }
                        return try databaseBrokerCommandClientResponse(
                            for: request,
                            requestID: requestID)
                    },
                    close: {
                        socket.close()
                        if registry.socket(for: cancelledOperationID) === socket {
                            blocked.close()
                        }
                    })
            }))
    let cancelledTask = Task {
        try await client.send(cancelledRequest)
    }
    let completedTask = Task {
        try await client.send(completedRequest)
    }

    await blocked.waitUntilEntered()
    cancelledTask.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await cancelledTask.value
    }
    let completedResponse = try await completedTask.value

    let cancelledSocket = registry.socket(for: cancelledOperationID)
    let completedSocket = registry.socket(for: completedOperationID)
    #expect(cancelledSocket != nil)
    #expect(completedSocket != nil)
    #expect(cancelledSocket !== completedSocket)
    #expect(cancelledSocket?.closeCountValue() == 1)
    #expect(completedSocket?.closeCountValue() == 1)
    #expect(completedResponse.operationGetResult?.payload?.operation == nil)
}

@Test func databaseBrokerCommandClientClosesConnectionCreatedAfterCancellation() async {
    let factoryGate = DatabaseBrokerCommandClientFactoryGate()
    let socket = DatabaseBrokerCommandClientBlockingSocket()
    let request = DatabaseBrokerCommandRequest.connectionList(
        DatabaseConnectionListRequest())
    let client = DatabaseBrokerCommandClient(
        dependencies: DatabaseBrokerCommandClientDependencies(
            ensureReady: {},
            makeConnection: { _ in
                factoryGate.enterAndBlock()
                return DatabaseBrokerCommandClientConnection(
                    request: { _, _, _ in
                        throw DatabaseBrokerCommandClientTestError.injected(
                            "request must not run")
                    },
                    close: {
                        socket.close()
                    })
            }))
    let task = Task {
        try await client.send(request)
    }

    await factoryGate.waitUntilEntered()
    task.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
    factoryGate.release()
    await socket.waitUntilClosed()

    #expect(socket.closeCountValue() == 1)
}

@Test func databaseBrokerCommandClientCancellationAfterWriteIsOutcomeUnknown() async {
    let blocked = DatabaseBrokerCommandClientBlockingSocket()
    let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "E98B20EF-7B80-449F-AC5F-E7E6DE29ED34")!)
    let request = DatabaseBrokerCommandRequest.operationGet(
        DatabaseOperationGetRequest(operationID: operationID))
    let client = DatabaseBrokerCommandClient(
        dependencies: DatabaseBrokerCommandClientDependencies(
            ensureReady: {},
            makeConnection: { _ in
                DatabaseBrokerCommandClientConnection(
                    request: { _, _, _ in
                        try blocked.waitThenFail(bytesWritten: 1)
                    },
                    close: {
                        blocked.close()
                    })
            }))
    let task = Task {
        try await client.send(request)
    }

    await blocked.waitUntilEntered()
    task.cancel()
    await #expect(throws: DatabaseBrokerCommandClientError.outcomeUnknown) {
        _ = try await task.value
    }
    #expect(blocked.closeCountValue() == 1)
}

private func databaseBrokerCommandClientFailingClient(
    recorder: DatabaseBrokerCommandClientTestRecorder,
    error: Error
) -> DatabaseBrokerCommandClient {
    DatabaseBrokerCommandClient(
        dependencies: DatabaseBrokerCommandClientDependencies(
            ensureReady: {
                recorder.record(.readiness)
            },
            makeConnection: { _ in
                recorder.record(.connection)
                return DatabaseBrokerCommandClientConnection(
                    request: { request, requestID, _ in
                        recorder.recordRequest(
                            request,
                            requestID: requestID,
                            isMainThread: Thread.isMainThread)
                        throw error
                    },
                    close: {
                        recorder.record(.close)
                    })
            }))
}

private func databaseBrokerCommandClientMutationApplyRequest(
    operationID: DatabaseOperationID
) -> DatabaseBrokerCommandRequest {
    .mutationApply(
        DatabaseMutationApplyRequest(
            mutation: DatabaseDestructiveRequest(
                target: DatabaseOperationFixtures.target,
                payload: .relational(
                    product: .postgresql,
                    statement: "DELETE FROM invoices WHERE id = $1",
                    parameters: [
                        DatabaseMutationParameter(
                            name: "id",
                            value: .signedInteger(42))
                    ])),
            token: DatabaseConfirmationToken(rawValue: "signed.payload"),
            confirmationText: "Orders invoices",
            operation: DatabaseOperationContext(operationID: operationID)))
}

private func databaseBrokerCommandClientResponse(
    for request: DatabaseBrokerCommandRequest,
    requestID: UUID
) throws -> DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse> {
    let metadata = DatabaseResultMetadata(
        completeness: DatabaseResultCompleteness(state: .complete))
    let payload: DatabaseBrokerCommandResponse
    switch request {
    case .operationGet:
        payload = .operationGet(
            .success(
                DatabaseOperationGetResult(operation: nil),
                metadata: metadata))
    case .operationCancel(let cancellation):
        payload = .operationCancel(
            .success(
                DatabaseOperationCancelResult(
                    operationID: cancellation.operationID,
                    disposition: .accepted,
                    cancellationSupport: .cooperative),
                metadata: metadata))
    case .connectionList:
        payload = .connectionList(
            .success(
                DatabaseConnectionListResult(connections: []),
                metadata: metadata))
    default:
        throw DatabaseBrokerCommandClientTestError.unsupportedRequest
    }
    return try payload.envelope(
        matching: request.envelope(requestID: requestID, sequence: 0),
        sequence: 0)
}
