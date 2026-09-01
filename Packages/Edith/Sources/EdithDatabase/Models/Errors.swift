import Foundation

public enum DatabaseErrorCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case invalidRequest
    case connectionFailed
    case authenticationFailed
    case tlsFailed
    case tunnelFailed
    case permissionDenied
    case unsupported
    case readOnlyViolation
    case confirmationRequired
    case confirmationInvalid
    case conflict
    case timeout
    case cancelled
    case server
    case network
    case decoding
    case partialFailure
    case resourceLimit
    case internalFailure
}

public enum DatabaseRetryAction: String, CaseIterable, Codable, Hashable, Sendable {
    case none
    case retry
    case reconnect
    case reauthenticate
    case refreshCapabilities
    case createNewPreview
    case userDecision
}

public struct DatabaseRetryGuidance: Codable, Hashable, Sendable {
    public let action: DatabaseRetryAction
    public let afterMilliseconds: UInt64?
    public let message: String?

    public init(
        action: DatabaseRetryAction,
        afterMilliseconds: UInt64? = nil,
        message: String? = nil
    ) {
        self.action = action
        self.afterMilliseconds = afterMilliseconds
        self.message = message
    }
}

public struct DatabaseErrorDetail: Codable, Hashable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct DatabaseErrorEnvelope: Error, Codable, Hashable, Sendable {
    public let category: DatabaseErrorCategory
    public let message: String
    public let productCode: String?
    public let target: DatabaseTargetIdentifier?
    public let retry: DatabaseRetryGuidance
    public let partialResult: DatabaseResultCompleteness?
    public let details: [DatabaseErrorDetail]

    public init(
        category: DatabaseErrorCategory,
        message: String,
        productCode: String? = nil,
        target: DatabaseTargetIdentifier? = nil,
        retry: DatabaseRetryGuidance = DatabaseRetryGuidance(action: .none),
        partialResult: DatabaseResultCompleteness? = nil,
        details: [DatabaseErrorDetail] = []
    ) {
        self.category = category
        self.message = message
        self.productCode = productCode
        self.target = target
        self.retry = retry
        self.partialResult = partialResult
        self.details = details
    }
}

public enum DatabaseWarningSeverity: String, CaseIterable, Codable, Hashable, Sendable {
    case information
    case caution
    case high
}

public struct DatabaseWarning: Codable, Hashable, Sendable {
    public let code: String
    public let message: String
    public let severity: DatabaseWarningSeverity
    public let target: DatabaseTargetIdentifier?

    public init(
        code: String,
        message: String,
        severity: DatabaseWarningSeverity,
        target: DatabaseTargetIdentifier? = nil
    ) {
        self.code = code
        self.message = message
        self.severity = severity
        self.target = target
    }
}

public struct DatabasePartialFailure: Codable, Hashable, Sendable {
    public let itemIndex: UInt64?
    public let itemIdentifier: String?
    public let target: DatabaseTargetIdentifier?
    public let error: DatabaseErrorEnvelope

    public init(
        itemIndex: UInt64? = nil,
        itemIdentifier: String? = nil,
        target: DatabaseTargetIdentifier? = nil,
        error: DatabaseErrorEnvelope
    ) {
        self.itemIndex = itemIndex
        self.itemIdentifier = itemIdentifier
        self.target = target
        self.error = error
    }
}
