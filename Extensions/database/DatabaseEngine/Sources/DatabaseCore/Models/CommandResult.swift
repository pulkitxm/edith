import Foundation

public enum DatabaseCommandResultStatus: String, CaseIterable, Codable, Hashable, Sendable {
    case succeeded
    case partiallySucceeded
    case failed
}

public struct DatabaseEmptyPayload: Codable, Hashable, Sendable {
    public init() {}
}

public struct DatabaseResultMetadata: Codable, Hashable, Sendable {
    public let operation: DatabaseOperationRecordSummary?
    public let completeness: DatabaseResultCompleteness
    public let count: DatabaseCountMetadata?
    public let warnings: [DatabaseWarning]
    public let partialFailures: [DatabasePartialFailure]

    public init(
        operation: DatabaseOperationRecordSummary? = nil,
        completeness: DatabaseResultCompleteness,
        count: DatabaseCountMetadata? = nil,
        warnings: [DatabaseWarning] = [],
        partialFailures: [DatabasePartialFailure] = []
    ) {
        self.operation = operation
        self.completeness = completeness
        self.count = count
        self.warnings = warnings
        self.partialFailures = partialFailures
    }
}

public enum DatabaseCommandResultError: Error, Equatable, Sendable {
    case missingPayload(DatabaseCommandResultStatus)
    case unexpectedPayload
    case missingError
    case unexpectedError
}

public struct DatabaseCommandResult<Payload: Sendable>: Sendable {
    public let status: DatabaseCommandResultStatus
    public let payload: Payload?
    public let error: DatabaseErrorEnvelope?
    public let metadata: DatabaseResultMetadata

    private init(
        status: DatabaseCommandResultStatus,
        payload: Payload?,
        error: DatabaseErrorEnvelope?,
        metadata: DatabaseResultMetadata
    ) {
        self.status = status
        self.payload = payload
        self.error = error
        self.metadata = metadata
    }

    public static func success(
        _ payload: Payload,
        metadata: DatabaseResultMetadata
    ) -> Self {
        Self(status: .succeeded, payload: payload, error: nil, metadata: metadata)
    }

    public static func partial(
        _ payload: Payload,
        error: DatabaseErrorEnvelope? = nil,
        metadata: DatabaseResultMetadata
    ) -> Self {
        Self(status: .partiallySucceeded, payload: payload, error: error, metadata: metadata)
    }

    public static func failure(
        _ error: DatabaseErrorEnvelope,
        metadata: DatabaseResultMetadata
    ) -> Self {
        Self(status: .failed, payload: nil, error: error, metadata: metadata)
    }
}

extension DatabaseCommandResult: Equatable where Payload: Equatable {}
extension DatabaseCommandResult: Hashable where Payload: Hashable {}

extension DatabaseCommandResult: Codable where Payload: Codable {
    private enum CodingKeys: String, CodingKey {
        case status
        case payload
        case error
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(DatabaseCommandResultStatus.self, forKey: .status)
        let payload = try container.decodeIfPresent(Payload.self, forKey: .payload)
        let error = try container.decodeIfPresent(DatabaseErrorEnvelope.self, forKey: .error)
        let metadata = try container.decode(DatabaseResultMetadata.self, forKey: .metadata)

        switch status {
        case .succeeded:
            guard payload != nil else { throw DatabaseCommandResultError.missingPayload(status) }
            guard error == nil else { throw DatabaseCommandResultError.unexpectedError }
        case .partiallySucceeded:
            guard payload != nil else { throw DatabaseCommandResultError.missingPayload(status) }
        case .failed:
            guard payload == nil else { throw DatabaseCommandResultError.unexpectedPayload }
            guard error != nil else { throw DatabaseCommandResultError.missingError }
        }

        self.init(status: status, payload: payload, error: error, metadata: metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(payload, forKey: .payload)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(metadata, forKey: .metadata)
    }
}
