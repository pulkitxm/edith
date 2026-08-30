import Foundation

public struct DatabaseConnectRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let connectionID: DatabaseConnectionID
    public let operation: DatabaseOperationContext

    public init(
        version: Int = DatabaseConnectRequest.schemaVersion,
        connectionID: DatabaseConnectionID,
        operation: DatabaseOperationContext = DatabaseOperationContext()
    ) {
        self.version = version
        self.connectionID = connectionID
        self.operation = operation
    }
}

public struct DatabaseConnectResult: Codable, Hashable, Sendable {
    public let connection: DatabaseConnectionIdentity
    public let productIdentity: DatabaseProductIdentity
    public let capabilities: DatabaseCapabilityReport
    public let connectedAt: Date

    public init(
        connection: DatabaseConnectionIdentity,
        productIdentity: DatabaseProductIdentity,
        capabilities: DatabaseCapabilityReport,
        connectedAt: Date
    ) {
        self.connection = connection
        self.productIdentity = productIdentity
        self.capabilities = capabilities
        self.connectedAt = connectedAt
    }
}

public struct DatabaseDisconnectRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let connectionID: DatabaseConnectionID
    public let operation: DatabaseOperationContext

    public init(
        version: Int = DatabaseDisconnectRequest.schemaVersion,
        connectionID: DatabaseConnectionID,
        operation: DatabaseOperationContext = DatabaseOperationContext()
    ) {
        self.version = version
        self.connectionID = connectionID
        self.operation = operation
    }
}

public struct DatabaseDisconnectResult: Codable, Hashable, Sendable {
    public let connection: DatabaseConnectionIdentity
    public let disconnected: Bool
    public let disconnectedAt: Date

    public init(
        connection: DatabaseConnectionIdentity,
        disconnected: Bool,
        disconnectedAt: Date
    ) {
        self.connection = connection
        self.disconnected = disconnected
        self.disconnectedAt = disconnectedAt
    }
}

extension DatabaseOperationKind {
    public static let databaseConnect: Self = "database.connection.connect"
    public static let databaseDisconnect: Self = "database.connection.disconnect"
    public static let databaseConnectionTest: Self = "database.connection.test"
    public static let databaseCapabilities: Self = "database.capabilities"
    public static let databaseBrowse: Self = "database.browse"
    public static let databaseQuery: Self = "database.query"
    public static let databaseMutationPreview: Self = "database.mutation.preview"
    public static let databaseMutationApply: Self = "database.mutation.apply"
}
