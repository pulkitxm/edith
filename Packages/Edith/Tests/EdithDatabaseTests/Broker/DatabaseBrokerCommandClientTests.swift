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

    func recordRequest(
        _ request: DatabaseBrokerCommandRequest,
        requestID: UUID,
        isMainThread: Bool
    ) {
        lock.withLock {
            events.append(.request)
            requestCount += 1
            observedOperationIDs.append(request.operationID)
            observedRequestIDs.append(requestID)
            observedMainThread = observedMainThread || isMainThread
        }
    }

    func snapshot() -> (
        events: [DatabaseBrokerCommandClientTestEvent],
        connections: Int,
        requests: Int,
        closes: Int,
        observedMainThread: Bool,
        operationIDs: [DatabaseOperationID?],
        requestIDs: [UUID]
    ) {
        lock.withLock {
            (
                events,
                connectionCount,
                requestCount,
                closeCount,
                observedMainThread,
                observedOperationIDs,
                observedRequestIDs
            )
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
            makeConnection: {
                recorder.record(.connection)
                return DatabaseBrokerCommandClientConnection(
                    request: { request, observedRequestID in
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
            makeConnection: {
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
            makeConnection: {
                let socket = DatabaseBrokerCommandClientBlockingSocket()
                return DatabaseBrokerCommandClientConnection(
                    request: { request, requestID in
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
            makeConnection: {
                factoryGate.enterAndBlock()
                return DatabaseBrokerCommandClientConnection(
                    request: { _, _ in
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
            makeConnection: {
                DatabaseBrokerCommandClientConnection(
                    request: { _, _ in
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
            makeConnection: {
                recorder.record(.connection)
                return DatabaseBrokerCommandClientConnection(
                    request: { request, requestID in
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
