import Foundation

public enum DatabasePageSizeError: Error, Equatable, Sendable {
    case outOfBounds(requested: Int, minimum: Int, maximum: Int)
}

public struct DatabasePageSize: Codable, Hashable, Sendable {
    public static let range = 1...2_000
    public static let defaultSize = DatabasePageSize(unchecked: 200)
    public static let maximumSize = DatabasePageSize(unchecked: 2_000)

    public let value: Int

    public init(_ value: Int) throws {
        guard Self.range.contains(value) else {
            throw DatabasePageSizeError.outOfBounds(
                requested: value,
                minimum: Self.range.lowerBound,
                maximum: Self.range.upperBound)
        }
        self.value = value
    }

    private init(unchecked value: Int) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Database page size must be between 1 and 2000.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum DatabaseConsistencyPreference: String, CaseIterable, Codable, Hashable, Sendable {
    case productDefault
    case bestEffort
    case eventual
    case session
    case snapshot
    case strong
}

public struct DatabaseContinuationToken: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct DatabaseContinuationContext: Codable, Hashable, Sendable {
    public let connectionID: DatabaseConnectionID
    public let target: DatabaseTargetIdentifier
    public let requestDigest: String
    public let sortDigest: String
    public let projectionDigest: String

    public init(
        connectionID: DatabaseConnectionID,
        target: DatabaseTargetIdentifier,
        requestDigest: String,
        sortDigest: String,
        projectionDigest: String
    ) {
        self.connectionID = connectionID
        self.target = target
        self.requestDigest = requestDigest
        self.sortDigest = sortDigest
        self.projectionDigest = projectionDigest
    }
}

public struct DatabaseContinuationEnvelope: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let identifier: UUID
    public let context: DatabaseContinuationContext
    public let issuedAt: Date
    public let expiresAt: Date
    public let payload: Data
    public let signature: Data

    public init(
        version: Int = DatabaseContinuationEnvelope.schemaVersion,
        identifier: UUID,
        context: DatabaseContinuationContext,
        issuedAt: Date,
        expiresAt: Date,
        payload: Data,
        signature: Data
    ) {
        self.version = version
        self.identifier = identifier
        self.context = context
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.payload = payload
        self.signature = signature
    }
}

public struct DatabasePageRequest: Codable, Hashable, Sendable {
    public let pageSize: DatabasePageSize
    public let continuation: DatabaseContinuationToken?
    public let projection: DatabaseProjection?
    public let filter: DatabaseFilter?
    public let sorts: [DatabaseSort]
    public let consistency: DatabaseConsistencyPreference

    public init(
        pageSize: DatabasePageSize = .defaultSize,
        continuation: DatabaseContinuationToken? = nil,
        projection: DatabaseProjection? = nil,
        filter: DatabaseFilter? = nil,
        sorts: [DatabaseSort] = [],
        consistency: DatabaseConsistencyPreference = .productDefault
    ) {
        self.pageSize = pageSize
        self.continuation = continuation
        self.projection = projection
        self.filter = filter
        self.sorts = sorts
        self.consistency = consistency
    }
}

public struct DatabaseFieldDescriptor: Codable, Hashable, Sendable {
    public let path: DatabaseFieldPath
    public let displayName: String
    public let typeName: String
    public let isNullable: Bool
    public let isSortable: Bool
    public let isFilterable: Bool

    public init(
        path: DatabaseFieldPath,
        displayName: String,
        typeName: String,
        isNullable: Bool,
        isSortable: Bool,
        isFilterable: Bool
    ) {
        self.path = path
        self.displayName = displayName
        self.typeName = typeName
        self.isNullable = isNullable
        self.isSortable = isSortable
        self.isFilterable = isFilterable
    }
}

public struct DatabaseRecord: Codable, Hashable, Sendable {
    public let identity: DatabaseRecordIdentity?
    public let fields: [DatabaseObjectField]
    public let metadata: [DatabaseStringAttribute]

    public init(
        identity: DatabaseRecordIdentity? = nil,
        fields: [DatabaseObjectField],
        metadata: [DatabaseStringAttribute] = []
    ) {
        self.identity = identity
        self.fields = fields
        self.metadata = metadata
    }
}

public enum DatabaseCompletenessState: String, CaseIterable, Codable, Hashable, Sendable {
    case complete
    case partial
    case sampled
    case estimated
    case truncated
    case stale
}

public struct DatabaseResultCompleteness: Codable, Hashable, Sendable {
    public let state: DatabaseCompletenessState
    public let reason: String?

    public init(state: DatabaseCompletenessState, reason: String? = nil) {
        self.state = state
        self.reason = reason
    }
}

public enum DatabaseCountAccuracy: String, CaseIterable, Codable, Hashable, Sendable {
    case unknown
    case exact
    case estimated
    case lowerBound
    case upperBound
}

public struct DatabaseCountMetadata: Codable, Hashable, Sendable {
    public let value: UInt64?
    public let accuracy: DatabaseCountAccuracy

    public init(value: UInt64? = nil, accuracy: DatabaseCountAccuracy) {
        self.value = value
        self.accuracy = accuracy
    }
}

public struct DatabaseQueryTiming: Codable, Hashable, Sendable {
    public let durationMilliseconds: UInt64
    public let serverDurationMilliseconds: UInt64?

    public init(durationMilliseconds: UInt64, serverDurationMilliseconds: UInt64? = nil) {
        self.durationMilliseconds = durationMilliseconds
        self.serverDurationMilliseconds = serverDurationMilliseconds
    }
}

public struct DatabasePageMetadata: Codable, Hashable, Sendable {
    public let completeness: DatabaseResultCompleteness
    public let count: DatabaseCountMetadata
    public let timing: DatabaseQueryTiming?
    public let bytesReceived: UInt64?
    public let warnings: [DatabaseWarning]
    public let partialFailures: [DatabasePartialFailure]

    public init(
        completeness: DatabaseResultCompleteness,
        count: DatabaseCountMetadata,
        timing: DatabaseQueryTiming? = nil,
        bytesReceived: UInt64? = nil,
        warnings: [DatabaseWarning] = [],
        partialFailures: [DatabasePartialFailure] = []
    ) {
        self.completeness = completeness
        self.count = count
        self.timing = timing
        self.bytesReceived = bytesReceived
        self.warnings = warnings
        self.partialFailures = partialFailures
    }
}

public struct DatabasePage<Record>: Codable, Hashable, Sendable
where Record: Codable & Hashable & Sendable {
    public let records: [Record]
    public let fields: [DatabaseFieldDescriptor]
    public let nextContinuation: DatabaseContinuationToken?
    public let metadata: DatabasePageMetadata

    public init(
        records: [Record],
        fields: [DatabaseFieldDescriptor] = [],
        nextContinuation: DatabaseContinuationToken? = nil,
        metadata: DatabasePageMetadata
    ) {
        self.records = records
        self.fields = fields
        self.nextContinuation = nextContinuation
        self.metadata = metadata
    }
}
