import Foundation

public struct DatabaseConnectionListRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let search: DatabaseConnectionSearch

    public init(
        version: Int = DatabaseConnectionListRequest.schemaVersion,
        search: DatabaseConnectionSearch = DatabaseConnectionSearch()
    ) {
        self.version = version
        self.search = search
    }
}

public struct DatabaseConnectionListResult: Codable, Hashable, Sendable {
    public let connections: [DatabaseConnectionDefinition]

    public init(connections: [DatabaseConnectionDefinition]) {
        self.connections = connections
    }
}

public struct DatabaseConnectionGetRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let connectionID: DatabaseConnectionID

    public init(
        version: Int = DatabaseConnectionGetRequest.schemaVersion,
        connectionID: DatabaseConnectionID
    ) {
        self.version = version
        self.connectionID = connectionID
    }
}

public struct DatabaseConnectionGetResult: Codable, Hashable, Sendable {
    public let connection: DatabaseConnectionDefinition?

    public init(connection: DatabaseConnectionDefinition?) {
        self.connection = connection
    }
}

public struct DatabaseConnectionSaveRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let connection: DatabaseConnectionDefinition

    public init(
        version: Int = DatabaseConnectionSaveRequest.schemaVersion,
        connection: DatabaseConnectionDefinition
    ) {
        self.version = version
        self.connection = connection
    }
}

public struct DatabaseConnectionSaveResult: Codable, Hashable, Sendable {
    public let connection: DatabaseConnectionDefinition

    public init(connection: DatabaseConnectionDefinition) {
        self.connection = connection
    }
}

public struct DatabaseConnectionEditRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let connectionID: DatabaseConnectionID
    public let connection: DatabaseConnectionDefinition

    public init(
        version: Int = DatabaseConnectionEditRequest.schemaVersion,
        connectionID: DatabaseConnectionID,
        connection: DatabaseConnectionDefinition
    ) {
        self.version = version
        self.connectionID = connectionID
        self.connection = connection
    }
}

public struct DatabaseConnectionEditResult: Codable, Hashable, Sendable {
    public let connection: DatabaseConnectionDefinition

    public init(connection: DatabaseConnectionDefinition) {
        self.connection = connection
    }
}

public struct DatabaseConnectionDuplicateRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let connectionID: DatabaseConnectionID
    public let displayName: String

    public init(
        version: Int = DatabaseConnectionDuplicateRequest.schemaVersion,
        connectionID: DatabaseConnectionID,
        displayName: String
    ) {
        self.version = version
        self.connectionID = connectionID
        self.displayName = displayName
    }
}

public struct DatabaseConnectionDuplicateResult: Codable, Hashable, Sendable {
    public let sourceConnectionID: DatabaseConnectionID
    public let connection: DatabaseConnectionDefinition
    public let sharesCredentials: Bool
    public let sharedCredentialReferences: [DatabaseSecretReference]

    public init(
        sourceConnectionID: DatabaseConnectionID,
        connection: DatabaseConnectionDefinition,
        sharesCredentials: Bool,
        sharedCredentialReferences: [DatabaseSecretReference]
    ) {
        self.sourceConnectionID = sourceConnectionID
        self.connection = connection
        self.sharesCredentials = sharesCredentials
        self.sharedCredentialReferences = sharedCredentialReferences
    }
}

public struct DatabaseConnectionRenameRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let connectionID: DatabaseConnectionID
    public let displayName: String

    public init(
        version: Int = DatabaseConnectionRenameRequest.schemaVersion,
        connectionID: DatabaseConnectionID,
        displayName: String
    ) {
        self.version = version
        self.connectionID = connectionID
        self.displayName = displayName
    }
}

public struct DatabaseConnectionRenameResult: Codable, Hashable, Sendable {
    public let connection: DatabaseConnectionDefinition

    public init(connection: DatabaseConnectionDefinition) {
        self.connection = connection
    }
}

public struct DatabaseConnectionDeleteRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let connectionID: DatabaseConnectionID

    public init(
        version: Int = DatabaseConnectionDeleteRequest.schemaVersion,
        connectionID: DatabaseConnectionID
    ) {
        self.version = version
        self.connectionID = connectionID
    }
}

public struct DatabaseConnectionDeleteResult: Codable, Hashable, Sendable {
    public let connectionID: DatabaseConnectionID
    public let deleted: Bool
    public let disconnected: Bool

    public init(
        connectionID: DatabaseConnectionID,
        deleted: Bool,
        disconnected: Bool
    ) {
        self.connectionID = connectionID
        self.deleted = deleted
        self.disconnected = disconnected
    }
}

public struct DatabaseSavedQueryListRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let search: DatabaseSavedQuerySearch

    public init(
        version: Int = DatabaseSavedQueryListRequest.schemaVersion,
        search: DatabaseSavedQuerySearch = DatabaseSavedQuerySearch()
    ) {
        self.version = version
        self.search = search
    }
}

public struct DatabaseSavedQueryListResult: Codable, Hashable, Sendable {
    public let queries: [DatabaseSavedQuery]

    public init(queries: [DatabaseSavedQuery]) {
        self.queries = queries
    }
}

public struct DatabaseSavedQueryGetRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let queryID: DatabaseSavedQueryID

    public init(
        version: Int = DatabaseSavedQueryGetRequest.schemaVersion,
        queryID: DatabaseSavedQueryID
    ) {
        self.version = version
        self.queryID = queryID
    }
}

public struct DatabaseSavedQueryGetResult: Codable, Hashable, Sendable {
    public let query: DatabaseSavedQuery?

    public init(query: DatabaseSavedQuery?) {
        self.query = query
    }
}

public struct DatabaseSavedQuerySaveRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let query: DatabaseSavedQuery

    public init(
        version: Int = DatabaseSavedQuerySaveRequest.schemaVersion,
        query: DatabaseSavedQuery
    ) {
        self.version = version
        self.query = query
    }
}

public struct DatabaseSavedQuerySaveResult: Codable, Hashable, Sendable {
    public let query: DatabaseSavedQuery
    public let created: Bool

    public init(query: DatabaseSavedQuery, created: Bool) {
        self.query = query
        self.created = created
    }
}

public struct DatabaseSavedQueryDuplicateRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let queryID: DatabaseSavedQueryID
    public let name: String

    public init(
        version: Int = DatabaseSavedQueryDuplicateRequest.schemaVersion,
        queryID: DatabaseSavedQueryID,
        name: String
    ) {
        self.version = version
        self.queryID = queryID
        self.name = name
    }
}

public struct DatabaseSavedQueryDuplicateResult: Codable, Hashable, Sendable {
    public let sourceQueryID: DatabaseSavedQueryID
    public let query: DatabaseSavedQuery

    public init(sourceQueryID: DatabaseSavedQueryID, query: DatabaseSavedQuery) {
        self.sourceQueryID = sourceQueryID
        self.query = query
    }
}

public struct DatabaseSavedQueryRenameRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let queryID: DatabaseSavedQueryID
    public let name: String

    public init(
        version: Int = DatabaseSavedQueryRenameRequest.schemaVersion,
        queryID: DatabaseSavedQueryID,
        name: String
    ) {
        self.version = version
        self.queryID = queryID
        self.name = name
    }
}

public struct DatabaseSavedQueryRenameResult: Codable, Hashable, Sendable {
    public let query: DatabaseSavedQuery

    public init(query: DatabaseSavedQuery) {
        self.query = query
    }
}

public struct DatabaseSavedQueryDeleteRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let queryID: DatabaseSavedQueryID

    public init(
        version: Int = DatabaseSavedQueryDeleteRequest.schemaVersion,
        queryID: DatabaseSavedQueryID
    ) {
        self.version = version
        self.queryID = queryID
    }
}

public struct DatabaseSavedQueryDeleteResult: Codable, Hashable, Sendable {
    public let queryID: DatabaseSavedQueryID
    public let deleted: Bool

    public init(queryID: DatabaseSavedQueryID, deleted: Bool) {
        self.queryID = queryID
        self.deleted = deleted
    }
}
