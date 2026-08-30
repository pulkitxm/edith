import Foundation

public struct DatabaseSavedQueryID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }
}

public enum DatabaseSavedQueryLanguage: String, CaseIterable, Codable, Hashable, Sendable {
    case sql
    case redisCommand
    case mongoQuery
    case searchQueryDSL
    case clickHouseSQL
}

public struct DatabaseSavedQuery: Codable, Hashable, Sendable {
    public let id: DatabaseSavedQueryID
    public let connectionID: DatabaseConnectionID?
    public let name: String
    public let language: DatabaseSavedQueryLanguage
    public let text: String
    public let tags: [String]
    public let isFavorite: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: DatabaseSavedQueryID,
        connectionID: DatabaseConnectionID? = nil,
        name: String,
        language: DatabaseSavedQueryLanguage,
        text: String,
        tags: [String] = [],
        isFavorite: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.connectionID = connectionID
        self.name = name
        self.language = language
        self.text = text
        self.tags = tags
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum DatabaseConnectionOrder: String, CaseIterable, Codable, Hashable, Sendable {
    case name
    case recentlyUsed
    case recentlyUpdated
    case recentlyCreated
}

public struct DatabaseConnectionSearch: Codable, Hashable, Sendable {
    public let text: String?
    public let products: Set<DatabaseProduct>
    public let environments: Set<DatabaseEnvironmentKind>
    public let group: String?
    public let tags: Set<String>
    public let favoritesOnly: Bool
    public let order: DatabaseConnectionOrder
    public let limit: Int
    public let offset: Int

    public init(
        text: String? = nil,
        products: Set<DatabaseProduct> = [],
        environments: Set<DatabaseEnvironmentKind> = [],
        group: String? = nil,
        tags: Set<String> = [],
        favoritesOnly: Bool = false,
        order: DatabaseConnectionOrder = .recentlyUsed,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.text = text
        self.products = products
        self.environments = environments
        self.group = group
        self.tags = tags
        self.favoritesOnly = favoritesOnly
        self.order = order
        self.limit = limit
        self.offset = offset
    }
}

public enum DatabaseSavedQueryOrder: String, CaseIterable, Codable, Hashable, Sendable {
    case name
    case recentlyUpdated
    case recentlyCreated
}

public struct DatabaseSavedQuerySearch: Codable, Hashable, Sendable {
    public let text: String?
    public let connectionID: DatabaseConnectionID?
    public let languages: Set<DatabaseSavedQueryLanguage>
    public let tags: Set<String>
    public let favoritesOnly: Bool
    public let order: DatabaseSavedQueryOrder
    public let limit: Int
    public let offset: Int

    public init(
        text: String? = nil,
        connectionID: DatabaseConnectionID? = nil,
        languages: Set<DatabaseSavedQueryLanguage> = [],
        tags: Set<String> = [],
        favoritesOnly: Bool = false,
        order: DatabaseSavedQueryOrder = .recentlyUpdated,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.text = text
        self.connectionID = connectionID
        self.languages = languages
        self.tags = tags
        self.favoritesOnly = favoritesOnly
        self.order = order
        self.limit = limit
        self.offset = offset
    }
}

public struct DatabaseOperationHistorySearch: Codable, Hashable, Sendable {
    public let connectionID: DatabaseConnectionID?
    public let states: Set<DatabaseOperationState>
    public let kinds: Set<DatabaseOperationKind>
    public let before: Date?
    public let limit: Int

    public init(
        connectionID: DatabaseConnectionID? = nil,
        states: Set<DatabaseOperationState> = [],
        kinds: Set<DatabaseOperationKind> = [],
        before: Date? = nil,
        limit: Int = 200
    ) {
        self.connectionID = connectionID
        self.states = states
        self.kinds = kinds
        self.before = before
        self.limit = limit
    }
}

public struct DatabaseConfirmationReceipt: Codable, Hashable, Sendable {
    public let identifier: UUID
    public let effectDigest: String
    public let expiresAt: Date
    public let consumedAt: Date?

    public init(
        identifier: UUID,
        effectDigest: String,
        expiresAt: Date,
        consumedAt: Date? = nil
    ) {
        self.identifier = identifier
        self.effectDigest = effectDigest
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
    }
}

public enum DatabaseMetadataStoreError: Error, Equatable, Sendable {
    case invalidLimit(Int)
    case invalidOffset(Int)
    case valueTooLarge(name: String, bytes: Int, maximum: Int)
    case invalidValue(name: String)
    case connectionNotFound(DatabaseConnectionID)
    case savedQueryNotFound(DatabaseSavedQueryID)
    case corruptedRecord(kind: String, identifier: String)
}

public enum DatabaseOperationReservationResult: String, Codable, Hashable, Sendable {
    case reserved
    case operationIdentifierExists
    case connectionChangedOrMissing
}

public protocol DatabaseMetadataStore: Sendable {
    func saveConnection(_ definition: DatabaseConnectionDefinition) async throws
    func connection(id: DatabaseConnectionID) async throws -> DatabaseConnectionDefinition?
    func connections(matching search: DatabaseConnectionSearch) async throws
        -> [DatabaseConnectionDefinition]
    func deleteConnection(id: DatabaseConnectionID) async throws -> Bool
    func saveQuery(_ query: DatabaseSavedQuery) async throws
    func savedQuery(id: DatabaseSavedQueryID) async throws -> DatabaseSavedQuery?
    func savedQueries(matching search: DatabaseSavedQuerySearch) async throws
        -> [DatabaseSavedQuery]
    func deleteSavedQuery(id: DatabaseSavedQueryID) async throws -> Bool
    func createOperationIfAbsent(_ summary: DatabaseOperationRecordSummary) async throws -> Bool
    func reserveOperation(
        _ summary: DatabaseOperationRecordSummary,
        for connection: DatabaseConnectionDefinition
    ) async throws -> DatabaseOperationReservationResult
    func recordOperation(_ summary: DatabaseOperationRecordSummary) async throws
    func operation(id: DatabaseOperationID) async throws -> DatabaseOperationRecordSummary?
    func operations(matching search: DatabaseOperationHistorySearch) async throws
        -> [DatabaseOperationRecordSummary]
    func pruneOperations(finishedBefore date: Date) async throws -> Int
    func registerConfirmation(_ receipt: DatabaseConfirmationReceipt) async throws
    func consumeConfirmation(
        identifier: UUID,
        effectDigest: String,
        connection: DatabaseConnectionDefinition,
        consumedAt: Date
    ) async throws -> Bool
    func removeExpiredConfirmations(before date: Date) async throws -> Int
}
