import Foundation

public struct DatabaseOperationID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }
}

public struct DatabaseOperationKind: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }
}

public enum DatabaseOperationState: String, CaseIterable, Codable, Hashable, Sendable {
    case queued
    case running
    case cancelling
    case succeeded
    case failed
    case cancelled
    case partiallySucceeded
}

public enum DatabaseProgressKind: String, CaseIterable, Codable, Hashable, Sendable {
    case indeterminate
    case determinate
}

public enum DatabaseProgressUnit: String, CaseIterable, Codable, Hashable, Sendable {
    case records
    case bytes
    case pages
    case items
    case steps
}

public struct DatabaseOperationProgress: Codable, Hashable, Sendable {
    public let kind: DatabaseProgressKind
    public let completed: UInt64?
    public let total: UInt64?
    public let unit: DatabaseProgressUnit?
    public let message: String?

    public init(
        kind: DatabaseProgressKind,
        completed: UInt64? = nil,
        total: UInt64? = nil,
        unit: DatabaseProgressUnit? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.completed = completed
        self.total = total
        self.unit = unit
        self.message = message
    }

    public static func indeterminate(message: String? = nil) -> Self {
        Self(kind: .indeterminate, message: message)
    }

    public static func determinate(
        completed: UInt64,
        total: UInt64,
        unit: DatabaseProgressUnit,
        message: String? = nil
    ) -> Self {
        Self(
            kind: .determinate,
            completed: completed,
            total: total,
            unit: unit,
            message: message)
    }
}

public enum DatabaseCancellationSupport: String, CaseIterable, Codable, Hashable, Sendable {
    case unavailable
    case cooperative
    case serverSide
}

public enum DatabaseRetryClassification: String, CaseIterable, Codable, Hashable, Sendable {
    case never
    case safeIdempotent
    case requiresReconnect
    case requiresNewPreview
    case userDecision
}

public struct DatabaseOperationRecordSummary: Codable, Hashable, Sendable {
    public let id: DatabaseOperationID
    public let kind: DatabaseOperationKind
    public let state: DatabaseOperationState
    public let connection: DatabaseConnectionIdentity
    public let target: DatabaseTargetIdentifier?
    public let startedAt: Date?
    public let finishedAt: Date?
    public let deadline: Date?
    public let progress: DatabaseOperationProgress?
    public let cancellationSupport: DatabaseCancellationSupport
    public let retryClassification: DatabaseRetryClassification
    public let pageCount: UInt64
    public let recordCount: UInt64
    public let byteCount: UInt64
    public let warnings: [DatabaseWarning]
    public let partialFailures: [DatabasePartialFailure]
    public let error: DatabaseErrorEnvelope?

    public init(
        id: DatabaseOperationID,
        kind: DatabaseOperationKind,
        state: DatabaseOperationState,
        connection: DatabaseConnectionIdentity,
        target: DatabaseTargetIdentifier? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        deadline: Date? = nil,
        progress: DatabaseOperationProgress? = nil,
        cancellationSupport: DatabaseCancellationSupport,
        retryClassification: DatabaseRetryClassification,
        pageCount: UInt64 = 0,
        recordCount: UInt64 = 0,
        byteCount: UInt64 = 0,
        warnings: [DatabaseWarning] = [],
        partialFailures: [DatabasePartialFailure] = [],
        error: DatabaseErrorEnvelope? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.connection = connection
        self.target = target
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.deadline = deadline
        self.progress = progress
        self.cancellationSupport = cancellationSupport
        self.retryClassification = retryClassification
        self.pageCount = pageCount
        self.recordCount = recordCount
        self.byteCount = byteCount
        self.warnings = warnings
        self.partialFailures = partialFailures
        self.error = error
    }
}
