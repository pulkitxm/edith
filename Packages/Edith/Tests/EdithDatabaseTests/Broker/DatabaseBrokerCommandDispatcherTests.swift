import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerCommandDispatcherTestError: Error {
    case handlerFailure
}

private actor DatabaseBrokerCommandDispatcherTestGate {
    private var isOpen: Bool
    private var nextWaiterID = 0
    private var entries = 0
    private var blocked: [Int: CheckedContinuation<Void, Error>] = [:]
    private var observers:
        [(
            minimum: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []

    init(open: Bool = true) {
        isOpen = open
    }

    func enter() async throws {
        entries += 1
        let ready = observers.filter { entries >= $0.minimum }
        observers.removeAll { entries >= $0.minimum }
        for observer in ready {
            observer.continuation.resume()
        }
        try Task.checkCancellation()
        guard !isOpen else { return }

        let waiterID = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    blocked[waiterID] = continuation
                }
            }
        } onCancel: {
            Task<Void, Never> { await self.cancel(waiterID) }
        }
        try Task.checkCancellation()
    }

    func releaseAll() {
        isOpen = true
        let continuations = Array(blocked.values)
        blocked.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForEntries(_ minimum: Int = 1) async {
        if entries >= minimum {
            return
        }
        await withCheckedContinuation { continuation in
            observers.append((minimum, continuation))
        }
    }

    private func cancel(_ waiterID: Int) {
        blocked.removeValue(forKey: waiterID)?.resume(
            throwing: CancellationError())
    }
}

private enum DatabaseBrokerCommandDispatcherFixtures {
    static let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "6F58F511-A655-48DB-85E0-A521DA9A5E4A")!)
    static let otherOperationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "EAFB52F5-5DD3-46EF-8D3C-1312828214FE")!)
    static let savedQueryID = DatabaseSavedQueryID(
        rawValue: UUID(uuidString: "093740D1-C984-48BA-A59F-56F2E1117326")!)
    static let metadata = DatabaseResultMetadata(
        completeness: DatabaseResultCompleteness(state: .complete))
    static let error = DatabaseErrorEnvelope(
        category: .unsupported,
        message: "dispatcher fixture failure")

    static var operation: DatabaseOperationContext {
        DatabaseOperationContext(
            operationID: operationID,
            deadline: Date(timeIntervalSince1970: 1_900_000_000))
    }

    static var savedQuery: DatabaseSavedQuery {
        DatabaseSavedQuery(
            id: savedQueryID,
            connectionID: DatabaseConnectionFixtures.connectionID,
            name: "Recent invoices",
            language: .sql,
            text: "SELECT * FROM invoices ORDER BY created_at DESC",
            tags: ["billing"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    static var mutation: DatabaseDestructiveRequest {
        DatabaseDestructiveRequest(
            target: DatabaseOperationFixtures.target,
            payload: .relational(
                product: .postgresql,
                statement: "UPDATE invoices SET state = $1 WHERE id = $2",
                parameters: [
                    DatabaseMutationParameter(
                        name: "state",
                        value: .string("paid")),
                    DatabaseMutationParameter(
                        name: "id",
                        value: .signedInteger(42)),
                ]))
    }

    static func requests() throws -> [DatabaseBrokerCommandRequest] {
        [
            .connect(
                DatabaseConnectRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    operation: operation)),
            .disconnect(
                DatabaseDisconnectRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    operation: operation)),
            .connectionTest(
                DatabaseConnectionTestRequest(
                    connection: try DatabaseConnectionFixtures.connectionDefinition(),
                    operation: operation)),
            .connectionList(DatabaseConnectionListRequest()),
            .connectionGet(
                DatabaseConnectionGetRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID)),
            .connectionSave(
                DatabaseConnectionSaveRequest(
                    connection: try DatabaseConnectionFixtures.connectionDefinition())),
            .connectionEdit(
                DatabaseConnectionEditRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    connection: try DatabaseConnectionFixtures.connectionDefinition())),
            .connectionDuplicate(
                DatabaseConnectionDuplicateRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    displayName: "Orders copy")),
            .connectionRename(
                DatabaseConnectionRenameRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    displayName: "Orders primary")),
            .connectionDelete(
                DatabaseConnectionDeleteRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID)),
            .capabilities(
                DatabaseCapabilitiesRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    resolution: .refresh,
                    operation: operation)),
            .browse(
                DatabaseBrowseRequest(
                    target: DatabaseOperationFixtures.target,
                    operation: operation)),
            .query(
                DatabaseQueryRequest(
                    target: DatabaseOperationFixtures.target,
                    language: .sql,
                    command: "SELECT * FROM invoices",
                    operation: operation)),
            .mutationPreview(
                DatabaseMutationPreviewRequest(
                    mutation: mutation,
                    operation: operation)),
            .mutationApply(
                DatabaseMutationApplyRequest(
                    mutation: mutation,
                    token: DatabaseConfirmationToken(rawValue: "payload.signature"),
                    confirmationText: "Orders invoices",
                    operation: operation)),
            .mutationStatus(
                DatabaseMutationStatusRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    acceptedMutation: DatabaseAcceptedMutation(
                        operationID: otherOperationID,
                        serverOperationIdentifier: "server-task-42"),
                    operation: operation)),
            .mutationCancel(
                DatabaseMutationCancelRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    acceptedMutation: DatabaseAcceptedMutation(
                        operationID: otherOperationID,
                        serverOperationIdentifier: "server-task-42"),
                    operation: operation)),
            .mutationOutcomeGet(
                DatabaseMutationOutcomeGetRequest(operationID: operationID)),
            .savedQueryList(DatabaseSavedQueryListRequest()),
            .savedQueryGet(
                DatabaseSavedQueryGetRequest(queryID: savedQueryID)),
            .savedQuerySave(
                DatabaseSavedQuerySaveRequest(query: savedQuery)),
            .savedQueryDuplicate(
                DatabaseSavedQueryDuplicateRequest(
                    queryID: savedQueryID,
                    name: "Recent invoices copy")),
            .savedQueryRename(
                DatabaseSavedQueryRenameRequest(
                    queryID: savedQueryID,
                    name: "Latest invoices")),
            .savedQueryDelete(
                DatabaseSavedQueryDeleteRequest(queryID: savedQueryID)),
            .operationGet(
                DatabaseOperationGetRequest(operationID: operationID)),
            .operationList(DatabaseOperationListRequest()),
            .operationCancel(
                DatabaseOperationCancelRequest(operationID: operationID)),
        ]
    }

    static func requestIdentifier(_ index: Int) -> UUID {
        let suffix = String(format: "%012d", index + 1)
        return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }

    static func connectRequest(
        requestID: UUID,
        sequence: UInt64 = 0
    ) -> DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest> {
        DatabaseBrokerCommandRequest.connect(
            DatabaseConnectRequest(
                connectionID: DatabaseConnectionFixtures.connectionID,
                operation: operation)
        ).envelope(
            requestID: requestID,
            sequence: sequence)
    }

    static func failure<Payload: Sendable>() -> DatabaseCommandResult<Payload> {
        .failure(error, metadata: metadata)
    }
}

private actor DatabaseBrokerCommandDispatcherTestHandler: DatabaseBrokerCommandHandler {
    private let connectGate: DatabaseBrokerCommandDispatcherTestGate
    private var connectFailuresRemaining: Int
    private var recordedRequests: [DatabaseBrokerCommandRequest] = []

    init(
        connectGate: DatabaseBrokerCommandDispatcherTestGate =
            DatabaseBrokerCommandDispatcherTestGate(),
        connectFailuresRemaining: Int = 0
    ) {
        self.connectGate = connectGate
        self.connectFailuresRemaining = connectFailuresRemaining
    }

    func requests() -> [DatabaseBrokerCommandRequest] {
        recordedRequests
    }

    func connect(
        _ request: DatabaseConnectRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectResult> {
        recordedRequests.append(.connect(request))
        try await connectGate.enter()
        if connectFailuresRemaining > 0 {
            connectFailuresRemaining -= 1
            throw DatabaseBrokerCommandDispatcherTestError.handlerFailure
        }
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func disconnect(
        _ request: DatabaseDisconnectRequest
    ) async throws -> DatabaseCommandResult<DatabaseDisconnectResult> {
        recordedRequests.append(.disconnect(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func connectionTest(
        _ request: DatabaseConnectionTestRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionTestResult> {
        recordedRequests.append(.connectionTest(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func connectionList(
        _ request: DatabaseConnectionListRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionListResult> {
        recordedRequests.append(.connectionList(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func connectionGet(
        _ request: DatabaseConnectionGetRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionGetResult> {
        recordedRequests.append(.connectionGet(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func connectionSave(
        _ request: DatabaseConnectionSaveRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionSaveResult> {
        recordedRequests.append(.connectionSave(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func connectionEdit(
        _ request: DatabaseConnectionEditRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionEditResult> {
        recordedRequests.append(.connectionEdit(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func connectionDuplicate(
        _ request: DatabaseConnectionDuplicateRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionDuplicateResult> {
        recordedRequests.append(.connectionDuplicate(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func connectionRename(
        _ request: DatabaseConnectionRenameRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionRenameResult> {
        recordedRequests.append(.connectionRename(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func connectionDelete(
        _ request: DatabaseConnectionDeleteRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionDeleteResult> {
        recordedRequests.append(.connectionDelete(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func capabilities(
        _ request: DatabaseCapabilitiesRequest
    ) async throws -> DatabaseCommandResult<DatabaseCapabilitiesResult> {
        recordedRequests.append(.capabilities(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func browse(
        _ request: DatabaseBrowseRequest
    ) async throws -> DatabaseCommandResult<DatabaseBrowseResult> {
        recordedRequests.append(.browse(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func query(
        _ request: DatabaseQueryRequest
    ) async throws -> DatabaseCommandResult<DatabaseQueryResult> {
        recordedRequests.append(.query(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func mutationPreview(
        _ request: DatabaseMutationPreviewRequest
    ) async throws -> DatabaseCommandResult<DatabaseMutationPreviewResult> {
        recordedRequests.append(.mutationPreview(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func mutationApply(
        _ request: DatabaseMutationApplyRequest
    ) async throws -> DatabaseCommandResult<DatabaseMutationApplyResult> {
        recordedRequests.append(.mutationApply(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func mutationStatus(
        _ request: DatabaseMutationStatusRequest
    ) async throws -> DatabaseCommandResult<DatabaseMutationStatusResult> {
        recordedRequests.append(.mutationStatus(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func mutationCancel(
        _ request: DatabaseMutationCancelRequest
    ) async throws -> DatabaseCommandResult<DatabaseMutationCancelResult> {
        recordedRequests.append(.mutationCancel(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func mutationOutcomeGet(
        _ request: DatabaseMutationOutcomeGetRequest
    ) async throws -> DatabaseCommandResult<DatabaseMutationOutcomeGetResult> {
        recordedRequests.append(.mutationOutcomeGet(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func savedQueryList(
        _ request: DatabaseSavedQueryListRequest
    ) async throws -> DatabaseCommandResult<DatabaseSavedQueryListResult> {
        recordedRequests.append(.savedQueryList(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func savedQueryGet(
        _ request: DatabaseSavedQueryGetRequest
    ) async throws -> DatabaseCommandResult<DatabaseSavedQueryGetResult> {
        recordedRequests.append(.savedQueryGet(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func savedQuerySave(
        _ request: DatabaseSavedQuerySaveRequest
    ) async throws -> DatabaseCommandResult<DatabaseSavedQuerySaveResult> {
        recordedRequests.append(.savedQuerySave(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func savedQueryDuplicate(
        _ request: DatabaseSavedQueryDuplicateRequest
    ) async throws -> DatabaseCommandResult<DatabaseSavedQueryDuplicateResult> {
        recordedRequests.append(.savedQueryDuplicate(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func savedQueryRename(
        _ request: DatabaseSavedQueryRenameRequest
    ) async throws -> DatabaseCommandResult<DatabaseSavedQueryRenameResult> {
        recordedRequests.append(.savedQueryRename(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func savedQueryDelete(
        _ request: DatabaseSavedQueryDeleteRequest
    ) async throws -> DatabaseCommandResult<DatabaseSavedQueryDeleteResult> {
        recordedRequests.append(.savedQueryDelete(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func operationGet(
        _ request: DatabaseOperationGetRequest
    ) async throws -> DatabaseCommandResult<DatabaseOperationGetResult> {
        recordedRequests.append(.operationGet(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func operationList(
        _ request: DatabaseOperationListRequest
    ) async throws -> DatabaseCommandResult<DatabaseOperationListResult> {
        recordedRequests.append(.operationList(request))
        return DatabaseBrokerCommandDispatcherFixtures.failure()
    }

    func operationCancel(
        _ request: DatabaseOperationCancelRequest
    ) async throws -> DatabaseCommandResult<DatabaseOperationCancelResult> {
        recordedRequests.append(.operationCancel(request))
        return .success(
            DatabaseOperationCancelResult(
                operationID: request.operationID,
                disposition: .accepted,
                cancellationSupport: .serverSide),
            metadata: DatabaseBrokerCommandDispatcherFixtures.metadata)
    }
}

@Suite(.serialized)
struct DatabaseBrokerCommandDispatcherTests {
    @Test func dispatchesEveryTypedCommandAndPreservesEnvelopeIdentity() async throws {
        let handler = DatabaseBrokerCommandDispatcherTestHandler()
        let dispatcher = try DatabaseBrokerCommandDispatcher(handler: handler)
        let requests = try DatabaseBrokerCommandDispatcherFixtures.requests()

        for (index, request) in requests.enumerated() {
            let requestID = DatabaseBrokerCommandDispatcherFixtures.requestIdentifier(index)
            let envelope = request.envelope(
                requestID: requestID,
                sequence: UInt64(index))
            let responseSequence = UInt64(index + 100)

            let response = try await dispatcher.dispatch(
                envelope,
                responseSequence: responseSequence)

            #expect(response.kind == .response)
            #expect(response.requestID == requestID)
            #expect(response.operationID == request.operationID)
            #expect(response.sequence == responseSequence)
            #expect(response.payload.kind == request.kind)
            try DatabaseBrokerCommandEnvelopeValidator.validate(
                response,
                matching: envelope)
        }

        let recordedRequests = await handler.requests()
        #expect(recordedRequests == requests)
        #expect(recordedRequests.map(\.kind) == DatabaseBrokerCommandKind.allCases)
    }

    @Test func operationCancellationResultPreservesOperationIdentity() async throws {
        let handler = DatabaseBrokerCommandDispatcherTestHandler()
        let dispatcher = try DatabaseBrokerCommandDispatcher(handler: handler)
        let request = DatabaseBrokerCommandRequest.operationCancel(
            DatabaseOperationCancelRequest(
                operationID: DatabaseBrokerCommandDispatcherFixtures.operationID))
        let envelope = request.envelope(
            requestID: DatabaseBrokerCommandDispatcherFixtures.requestIdentifier(20),
            sequence: 4)

        let response = try await dispatcher.dispatch(
            envelope,
            responseSequence: 5)

        #expect(
            response.payload.operationCancelResult?.payload?.operationID
                == DatabaseBrokerCommandDispatcherFixtures.operationID)
        #expect(response.operationID == DatabaseBrokerCommandDispatcherFixtures.operationID)
    }

    @Test func rejectsInvalidEnvelopesBeforeReservationOrDispatch() async throws {
        let handler = DatabaseBrokerCommandDispatcherTestHandler()
        let dispatcher = try DatabaseBrokerCommandDispatcher(handler: handler)
        let request = DatabaseBrokerCommandRequest.connect(
            DatabaseConnectRequest(
                connectionID: DatabaseConnectionFixtures.connectionID,
                operation: DatabaseBrokerCommandDispatcherFixtures.operation))
        let envelope = DatabaseBrokerEnvelope(
            requestID: DatabaseBrokerCommandDispatcherFixtures.requestIdentifier(21),
            operationID: DatabaseBrokerCommandDispatcherFixtures.otherOperationID,
            sequence: 0,
            kind: .request,
            payload: request)

        await #expect(
            throws: DatabaseBrokerCommandContractError.operationIDMismatch(
                expected: DatabaseBrokerCommandDispatcherFixtures.operationID,
                actual: DatabaseBrokerCommandDispatcherFixtures.otherOperationID)
        ) {
            _ = try await dispatcher.dispatch(envelope, responseSequence: 1)
        }

        let count = await dispatcher.inFlightRequestCount
        let recordedRequests = await handler.requests()
        #expect(count == 0)
        #expect(recordedRequests.isEmpty)
    }

    @Test func enforcesConfigurationAndExactInFlightCapacityBounds() async throws {
        let handler = DatabaseBrokerCommandDispatcherTestHandler()

        _ = try DatabaseBrokerCommandDispatcher(
            handler: handler,
            maximumInFlightRequests: 1)
        _ = try DatabaseBrokerCommandDispatcher(
            handler: handler,
            maximumInFlightRequests: DatabaseBrokerCommandDispatcher
                .maximumSupportedInFlightRequests)
        #expect(
            throws:
                DatabaseBrokerCommandDispatcherError
                .invalidMaximumInFlightRequests(0)
        ) {
            _ = try DatabaseBrokerCommandDispatcher(
                handler: handler,
                maximumInFlightRequests: 0)
        }
        #expect(
            throws:
                DatabaseBrokerCommandDispatcherError
                .invalidMaximumInFlightRequests(
                    DatabaseBrokerCommandDispatcher.maximumSupportedInFlightRequests + 1)
        ) {
            _ = try DatabaseBrokerCommandDispatcher(
                handler: handler,
                maximumInFlightRequests: DatabaseBrokerCommandDispatcher
                    .maximumSupportedInFlightRequests + 1)
        }

        let gate = DatabaseBrokerCommandDispatcherTestGate(open: false)
        let gatedHandler = DatabaseBrokerCommandDispatcherTestHandler(connectGate: gate)
        let dispatcher = try DatabaseBrokerCommandDispatcher(
            handler: gatedHandler,
            maximumInFlightRequests: 3)
        let envelopes = (0..<4).map {
            DatabaseBrokerCommandDispatcherFixtures.connectRequest(
                requestID: DatabaseBrokerCommandDispatcherFixtures.requestIdentifier($0 + 30))
        }
        let tasks = envelopes.prefix(3).enumerated().map { index, envelope in
            Task {
                try await dispatcher.dispatch(
                    envelope,
                    responseSequence: UInt64(index + 1))
            }
        }
        await gate.waitForEntries(3)

        let reservedCount = await dispatcher.inFlightRequestCount
        #expect(reservedCount == 3)
        await #expect(
            throws: DatabaseBrokerCommandDispatcherError.duplicateInFlightRequestID(
                envelopes[0].requestID)
        ) {
            _ = try await dispatcher.dispatch(envelopes[0], responseSequence: 10)
        }
        await #expect(
            throws:
                DatabaseBrokerCommandDispatcherError
                .inFlightRequestCapacityExceeded(maximum: 3)
        ) {
            _ = try await dispatcher.dispatch(envelopes[3], responseSequence: 11)
        }

        await gate.releaseAll()
        for task in tasks {
            _ = try await task.value
        }
        let releasedCount = await dispatcher.inFlightRequestCount
        #expect(releasedCount == 0)
    }

    @Test func releasesReservationsAfterSuccessAndHandlerError() async throws {
        let handler = DatabaseBrokerCommandDispatcherTestHandler(
            connectFailuresRemaining: 1)
        let dispatcher = try DatabaseBrokerCommandDispatcher(handler: handler)
        let envelope = DatabaseBrokerCommandDispatcherFixtures.connectRequest(
            requestID: DatabaseBrokerCommandDispatcherFixtures.requestIdentifier(40))

        await #expect(throws: DatabaseBrokerCommandDispatcherTestError.handlerFailure) {
            _ = try await dispatcher.dispatch(envelope, responseSequence: 1)
        }
        let countAfterError = await dispatcher.inFlightRequestCount
        #expect(countAfterError == 0)

        _ = try await dispatcher.dispatch(envelope, responseSequence: 2)
        let countAfterSuccess = await dispatcher.inFlightRequestCount
        #expect(countAfterSuccess == 0)

        _ = try await dispatcher.dispatch(envelope, responseSequence: 3)
        let countAfterReuse = await dispatcher.inFlightRequestCount
        #expect(countAfterReuse == 0)
    }

    @Test func releasesReservationAfterTaskCancellation() async throws {
        let gate = DatabaseBrokerCommandDispatcherTestGate(open: false)
        let handler = DatabaseBrokerCommandDispatcherTestHandler(connectGate: gate)
        let dispatcher = try DatabaseBrokerCommandDispatcher(handler: handler)
        let envelope = DatabaseBrokerCommandDispatcherFixtures.connectRequest(
            requestID: DatabaseBrokerCommandDispatcherFixtures.requestIdentifier(41))
        let task = Task {
            try await dispatcher.dispatch(envelope, responseSequence: 1)
        }
        await gate.waitForEntries()

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let countAfterCancellation = await dispatcher.inFlightRequestCount
        #expect(countAfterCancellation == 0)

        await gate.releaseAll()
        _ = try await dispatcher.dispatch(envelope, responseSequence: 2)
        let countAfterReuse = await dispatcher.inFlightRequestCount
        #expect(countAfterReuse == 0)
    }

    @Test func statusAndCancellationCommandsProgressDuringSuspendedWork() async throws {
        let gate = DatabaseBrokerCommandDispatcherTestGate(open: false)
        let handler = DatabaseBrokerCommandDispatcherTestHandler(connectGate: gate)
        let dispatcher = try DatabaseBrokerCommandDispatcher(
            handler: handler,
            maximumInFlightRequests: 4)
        let suspended = DatabaseBrokerCommandDispatcherFixtures.connectRequest(
            requestID: DatabaseBrokerCommandDispatcherFixtures.requestIdentifier(50))
        let suspendedTask = Task {
            try await dispatcher.dispatch(suspended, responseSequence: 1)
        }
        await gate.waitForEntries()

        let requests = try DatabaseBrokerCommandDispatcherFixtures.requests()
        for (index, request) in requests.suffix(3).enumerated() {
            let envelope = request.envelope(
                requestID: DatabaseBrokerCommandDispatcherFixtures.requestIdentifier(
                    index + 51),
                sequence: UInt64(index + 2))
            let response = try await dispatcher.dispatch(
                envelope,
                responseSequence: UInt64(index + 20))
            #expect(response.payload.kind == request.kind)
        }

        let recordedBeforeRelease = await handler.requests()
        #expect(
            recordedBeforeRelease.map(\.kind)
                == [.connect, .operationGet, .operationList, .operationCancel])
        let suspendedCount = await dispatcher.inFlightRequestCount
        #expect(suspendedCount == 1)

        await gate.releaseAll()
        _ = try await suspendedTask.value
        let releasedCount = await dispatcher.inFlightRequestCount
        #expect(releasedCount == 0)
    }
}
