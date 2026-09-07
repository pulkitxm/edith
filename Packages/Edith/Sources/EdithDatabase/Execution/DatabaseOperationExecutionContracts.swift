import Foundation

public struct DatabaseOperationGetRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let operationID: DatabaseOperationID

    public init(
        version: Int = DatabaseOperationGetRequest.schemaVersion,
        operationID: DatabaseOperationID
    ) {
        self.version = version
        self.operationID = operationID
    }
}

public struct DatabaseOperationGetResult: Codable, Hashable, Sendable {
    public let operation: DatabaseOperationRecordSummary?

    public init(operation: DatabaseOperationRecordSummary?) {
        self.operation = operation
    }
}

public struct DatabaseOperationListRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let search: DatabaseOperationHistorySearch

    public init(
        version: Int = DatabaseOperationListRequest.schemaVersion,
        search: DatabaseOperationHistorySearch = DatabaseOperationHistorySearch()
    ) {
        self.version = version
        self.search = search
    }
}

public struct DatabaseOperationListResult: Codable, Hashable, Sendable {
    public let operations: [DatabaseOperationRecordSummary]

    public init(operations: [DatabaseOperationRecordSummary]) {
        self.operations = operations
    }
}

public enum DatabaseOperationCancellationDisposition: String, CaseIterable, Codable, Hashable,
    Sendable
{
    case accepted
    case alreadyFinished
    case notActive
    case notFound
}

public struct DatabaseOperationCancelRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let operationID: DatabaseOperationID

    public init(
        version: Int = DatabaseOperationCancelRequest.schemaVersion,
        operationID: DatabaseOperationID
    ) {
        self.version = version
        self.operationID = operationID
    }
}

public struct DatabaseOperationCancelResult: Codable, Hashable, Sendable {
    public let operationID: DatabaseOperationID
    public let disposition: DatabaseOperationCancellationDisposition
    public let cancellationSupport: DatabaseCancellationSupport
    public let operation: DatabaseOperationRecordSummary?

    public init(
        operationID: DatabaseOperationID,
        disposition: DatabaseOperationCancellationDisposition,
        cancellationSupport: DatabaseCancellationSupport,
        operation: DatabaseOperationRecordSummary? = nil
    ) {
        self.operationID = operationID
        self.disposition = disposition
        self.cancellationSupport = cancellationSupport
        self.operation = operation
    }
}
