import Foundation

public struct DatabaseOperationContext: Codable, Hashable, Sendable {
    public let operationID: DatabaseOperationID
    public let deadline: Date?

    public init(
        operationID: DatabaseOperationID = DatabaseOperationID(),
        deadline: Date? = nil
    ) {
        self.operationID = operationID
        self.deadline = deadline
    }
}

public struct DatabaseConnectionTestRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let connection: DatabaseConnectionDefinition
    public let operation: DatabaseOperationContext

    public init(
        version: Int = DatabaseConnectionTestRequest.schemaVersion,
        connection: DatabaseConnectionDefinition,
        operation: DatabaseOperationContext = DatabaseOperationContext()
    ) {
        self.version = version
        self.connection = connection
        self.operation = operation
    }
}

public struct DatabaseConnectionTestResult: Codable, Hashable, Sendable {
    public let connection: DatabaseConnectionIdentity
    public let productIdentity: DatabaseProductIdentity
    public let capabilities: DatabaseCapabilityReport
    public let latencyMilliseconds: UInt64
    public let testedAt: Date

    public init(
        connection: DatabaseConnectionIdentity,
        productIdentity: DatabaseProductIdentity,
        capabilities: DatabaseCapabilityReport,
        latencyMilliseconds: UInt64,
        testedAt: Date
    ) {
        self.connection = connection
        self.productIdentity = productIdentity
        self.capabilities = capabilities
        self.latencyMilliseconds = latencyMilliseconds
        self.testedAt = testedAt
    }
}

public enum DatabaseCapabilityResolution: String, CaseIterable, Codable, Hashable, Sendable {
    case cachedOrDiscover
    case refresh
}

public enum DatabaseCapabilityReportSource: String, CaseIterable, Codable, Hashable, Sendable {
    case cached
    case discovered
}

public struct DatabaseCapabilitiesRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let connectionID: DatabaseConnectionID
    public let resolution: DatabaseCapabilityResolution
    public let operation: DatabaseOperationContext

    public init(
        version: Int = DatabaseCapabilitiesRequest.schemaVersion,
        connectionID: DatabaseConnectionID,
        resolution: DatabaseCapabilityResolution = .cachedOrDiscover,
        operation: DatabaseOperationContext = DatabaseOperationContext()
    ) {
        self.version = version
        self.connectionID = connectionID
        self.resolution = resolution
        self.operation = operation
    }
}

public struct DatabaseCapabilitiesResult: Codable, Hashable, Sendable {
    public let report: DatabaseCapabilityReport
    public let source: DatabaseCapabilityReportSource

    public init(
        report: DatabaseCapabilityReport,
        source: DatabaseCapabilityReportSource
    ) {
        self.report = report
        self.source = source
    }
}

public struct DatabaseBrowseRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let target: DatabaseTargetIdentifier
    public let page: DatabasePageRequest
    public let operation: DatabaseOperationContext

    public init(
        version: Int = DatabaseBrowseRequest.schemaVersion,
        target: DatabaseTargetIdentifier,
        page: DatabasePageRequest = DatabasePageRequest(),
        operation: DatabaseOperationContext = DatabaseOperationContext()
    ) {
        self.version = version
        self.target = target
        self.page = page
        self.operation = operation
    }
}

public struct DatabaseBrowseResult: Codable, Hashable, Sendable {
    public let page: DatabasePage<DatabaseRecord>

    public init(page: DatabasePage<DatabaseRecord>) {
        self.page = page
    }
}

public typealias DatabaseQueryLanguage = DatabaseSavedQueryLanguage

public struct DatabaseQueryParameter: Codable, Hashable, Sendable {
    public let name: String?
    public let value: DatabaseValue

    public init(name: String? = nil, value: DatabaseValue) {
        self.name = name
        self.value = value
    }
}

public struct DatabaseQueryRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let target: DatabaseTargetIdentifier
    public let language: DatabaseQueryLanguage
    public let command: String
    public let parameters: [DatabaseQueryParameter]
    public let body: DatabaseValue?
    public let page: DatabasePageRequest
    public let operation: DatabaseOperationContext

    public init(
        version: Int = DatabaseQueryRequest.schemaVersion,
        target: DatabaseTargetIdentifier,
        language: DatabaseQueryLanguage,
        command: String,
        parameters: [DatabaseQueryParameter] = [],
        body: DatabaseValue? = nil,
        page: DatabasePageRequest = DatabasePageRequest(),
        operation: DatabaseOperationContext = DatabaseOperationContext()
    ) {
        self.version = version
        self.target = target
        self.language = language
        self.command = command
        self.parameters = parameters
        self.body = body
        self.page = page
        self.operation = operation
    }
}

public struct DatabaseQueryResult: Codable, Hashable, Sendable {
    public let page: DatabasePage<DatabaseRecord>

    public init(page: DatabasePage<DatabaseRecord>) {
        self.page = page
    }
}

public struct DatabaseMutationPreviewRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let mutation: DatabaseDestructiveRequest
    public let operation: DatabaseOperationContext

    public init(
        version: Int = DatabaseMutationPreviewRequest.schemaVersion,
        mutation: DatabaseDestructiveRequest,
        operation: DatabaseOperationContext = DatabaseOperationContext()
    ) {
        self.version = version
        self.mutation = mutation
        self.operation = operation
    }
}

public struct DatabaseMutationPreviewResult: Codable, Hashable, Sendable {
    public let preview: DatabaseDestructivePreview

    public init(preview: DatabaseDestructivePreview) {
        self.preview = preview
    }
}

public struct DatabaseMutationApplyRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let mutation: DatabaseDestructiveRequest
    public let token: DatabaseConfirmationToken
    public let confirmationText: String
    public let operation: DatabaseOperationContext

    public init(
        version: Int = DatabaseMutationApplyRequest.schemaVersion,
        mutation: DatabaseDestructiveRequest,
        token: DatabaseConfirmationToken,
        confirmationText: String,
        operation: DatabaseOperationContext = DatabaseOperationContext()
    ) {
        self.version = version
        self.mutation = mutation
        self.token = token
        self.confirmationText = confirmationText
        self.operation = operation
    }
}

public enum DatabaseMutationDisposition: String, CaseIterable, Codable, Hashable, Sendable {
    case completed
    case accepted
}

public struct DatabaseMutationApplyResult: Codable, Hashable, Sendable {
    public let disposition: DatabaseMutationDisposition
    public let affectedRecords: DatabaseCountMetadata
    public let returnedRecords: DatabasePage<DatabaseRecord>?
    public let serverOperationIdentifier: String?

    public init(
        disposition: DatabaseMutationDisposition,
        affectedRecords: DatabaseCountMetadata,
        returnedRecords: DatabasePage<DatabaseRecord>? = nil,
        serverOperationIdentifier: String? = nil
    ) {
        self.disposition = disposition
        self.affectedRecords = affectedRecords
        self.returnedRecords = returnedRecords
        self.serverOperationIdentifier = serverOperationIdentifier
    }
}
