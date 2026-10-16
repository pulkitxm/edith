import Foundation

public enum DatabaseMutationOperationState: String, CaseIterable, Codable, Hashable, Sendable {
    case accepted
    case running
    case cancelling
    case completed
    case failed
    case cancelled
}

public struct DatabaseMutationStatusRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 2

    public let version: Int
    public let connectionID: DatabaseConnectionID
    public let acceptedMutation: DatabaseAcceptedMutation
    public let operation: DatabaseOperationContext

    public init(
        version: Int = DatabaseMutationStatusRequest.schemaVersion,
        connectionID: DatabaseConnectionID,
        acceptedMutation: DatabaseAcceptedMutation,
        operation: DatabaseOperationContext = DatabaseOperationContext()
    ) {
        self.version = version
        self.connectionID = connectionID
        self.acceptedMutation = acceptedMutation
        self.operation = operation
    }
}

public struct DatabaseMutationStatusResult: Codable, Hashable, Sendable {
    public let acceptedMutation: DatabaseAcceptedMutation
    public let state: DatabaseMutationOperationState
    public let progress: DatabaseOperationProgress?
    public let outcome: DatabaseMutationApplyResult?
    public let error: DatabaseErrorEnvelope?
    public let warnings: [DatabaseWarning]

    public init(
        acceptedMutation: DatabaseAcceptedMutation,
        state: DatabaseMutationOperationState,
        progress: DatabaseOperationProgress? = nil,
        outcome: DatabaseMutationApplyResult? = nil,
        error: DatabaseErrorEnvelope? = nil,
        warnings: [DatabaseWarning] = []
    ) {
        self.acceptedMutation = acceptedMutation
        self.state = state
        self.progress = progress
        self.outcome = outcome
        self.error = error
        self.warnings = warnings
    }
}

public enum DatabaseMutationCancellationDisposition: String, CaseIterable, Codable, Hashable,
    Sendable
{
    case accepted
    case alreadyFinished
    case notFound
    case unavailable
}

public struct DatabaseMutationCancelRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 2

    public let version: Int
    public let connectionID: DatabaseConnectionID
    public let acceptedMutation: DatabaseAcceptedMutation
    public let operation: DatabaseOperationContext

    public init(
        version: Int = DatabaseMutationCancelRequest.schemaVersion,
        connectionID: DatabaseConnectionID,
        acceptedMutation: DatabaseAcceptedMutation,
        operation: DatabaseOperationContext = DatabaseOperationContext()
    ) {
        self.version = version
        self.connectionID = connectionID
        self.acceptedMutation = acceptedMutation
        self.operation = operation
    }
}

public struct DatabaseMutationCancelResult: Codable, Hashable, Sendable {
    public let acceptedMutation: DatabaseAcceptedMutation
    public let disposition: DatabaseMutationCancellationDisposition
    public let status: DatabaseMutationStatusResult?

    public init(
        acceptedMutation: DatabaseAcceptedMutation,
        disposition: DatabaseMutationCancellationDisposition,
        status: DatabaseMutationStatusResult? = nil
    ) {
        self.acceptedMutation = acceptedMutation
        self.disposition = disposition
        self.status = status
    }
}

public struct DatabaseMutationOutcomeGetRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let operationID: DatabaseOperationID

    public init(
        version: Int = DatabaseMutationOutcomeGetRequest.schemaVersion,
        operationID: DatabaseOperationID
    ) {
        self.version = version
        self.operationID = operationID
    }
}

public struct DatabaseMutationOutcomeGetResult: Codable, Hashable, Sendable {
    public let operation: DatabaseOperationRecordSummary?
    public let outcome: DatabaseMutationApplyResult?

    public init(
        operation: DatabaseOperationRecordSummary?,
        outcome: DatabaseMutationApplyResult?
    ) {
        self.operation = operation
        self.outcome = outcome
    }
}
