import Foundation

public enum DatabaseBrokerCommandDispatcherError: Error, Equatable, Sendable {
    case invalidMaximumInFlightRequests(Int)
    case duplicateInFlightRequestID(UUID)
    case inFlightRequestCapacityExceeded(maximum: Int)
}

public protocol DatabaseBrokerCommandHandler: Sendable {
    func connect(
        _ request: DatabaseConnectRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectResult>

    func disconnect(
        _ request: DatabaseDisconnectRequest
    ) async throws -> DatabaseCommandResult<DatabaseDisconnectResult>

    func connectionTest(
        _ request: DatabaseConnectionTestRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionTestResult>

    func capabilities(
        _ request: DatabaseCapabilitiesRequest
    ) async throws -> DatabaseCommandResult<DatabaseCapabilitiesResult>

    func browse(
        _ request: DatabaseBrowseRequest
    ) async throws -> DatabaseCommandResult<DatabaseBrowseResult>

    func query(
        _ request: DatabaseQueryRequest
    ) async throws -> DatabaseCommandResult<DatabaseQueryResult>

    func mutationPreview(
        _ request: DatabaseMutationPreviewRequest
    ) async throws -> DatabaseCommandResult<DatabaseMutationPreviewResult>

    func mutationApply(
        _ request: DatabaseMutationApplyRequest
    ) async throws -> DatabaseCommandResult<DatabaseMutationApplyResult>

    func operationGet(
        _ request: DatabaseOperationGetRequest
    ) async throws -> DatabaseCommandResult<DatabaseOperationGetResult>

    func operationList(
        _ request: DatabaseOperationListRequest
    ) async throws -> DatabaseCommandResult<DatabaseOperationListResult>

    func operationCancel(
        _ request: DatabaseOperationCancelRequest
    ) async throws -> DatabaseCommandResult<DatabaseOperationCancelResult>
}

public actor DatabaseBrokerCommandDispatcher {
    public static let defaultMaximumInFlightRequests = 64
    public static let maximumSupportedInFlightRequests = 256

    private let handler: any DatabaseBrokerCommandHandler
    private let maximumInFlightRequests: Int
    private var inFlightRequestIDs: Set<UUID> = []

    public init(
        handler: any DatabaseBrokerCommandHandler,
        maximumInFlightRequests: Int = DatabaseBrokerCommandDispatcher
            .defaultMaximumInFlightRequests
    ) throws {
        guard
            (1...Self.maximumSupportedInFlightRequests).contains(
                maximumInFlightRequests)
        else {
            throw DatabaseBrokerCommandDispatcherError.invalidMaximumInFlightRequests(
                maximumInFlightRequests)
        }
        self.handler = handler
        self.maximumInFlightRequests = maximumInFlightRequests
    }

    public var inFlightRequestCount: Int {
        inFlightRequestIDs.count
    }

    public func dispatch(
        _ request: DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest>,
        responseSequence: UInt64
    ) async throws -> DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse> {
        try DatabaseBrokerCommandEnvelopeValidator.validate(request)
        try reserve(request.requestID)
        defer { inFlightRequestIDs.remove(request.requestID) }

        let response = try await dispatch(request.payload)
        return try response.envelope(
            matching: request,
            sequence: responseSequence)
    }

    private func reserve(_ requestID: UUID) throws {
        guard !inFlightRequestIDs.contains(requestID) else {
            throw DatabaseBrokerCommandDispatcherError.duplicateInFlightRequestID(
                requestID)
        }
        guard inFlightRequestIDs.count < maximumInFlightRequests else {
            throw DatabaseBrokerCommandDispatcherError.inFlightRequestCapacityExceeded(
                maximum: maximumInFlightRequests)
        }
        inFlightRequestIDs.insert(requestID)
    }

    private func dispatch(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        switch request {
        case .connect(let command):
            .connect(try await handler.connect(command))
        case .disconnect(let command):
            .disconnect(try await handler.disconnect(command))
        case .connectionTest(let command):
            .connectionTest(try await handler.connectionTest(command))
        case .capabilities(let command):
            .capabilities(try await handler.capabilities(command))
        case .browse(let command):
            .browse(try await handler.browse(command))
        case .query(let command):
            .query(try await handler.query(command))
        case .mutationPreview(let command):
            .mutationPreview(try await handler.mutationPreview(command))
        case .mutationApply(let command):
            .mutationApply(try await handler.mutationApply(command))
        case .operationGet(let command):
            .operationGet(try await handler.operationGet(command))
        case .operationList(let command):
            .operationList(try await handler.operationList(command))
        case .operationCancel(let command):
            .operationCancel(try await handler.operationCancel(command))
        }
    }
}
