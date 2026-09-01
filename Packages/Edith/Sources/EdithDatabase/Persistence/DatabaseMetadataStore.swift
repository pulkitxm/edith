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

public struct DatabaseRuntimeOwnerToken: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }
}

public struct DatabaseRuntimeOwnerRecord: Codable, Hashable, Sendable {
    public let token: DatabaseRuntimeOwnerToken
    public let claimedAt: Date
    public let releasedAt: Date?
    public let recoveryPending: Bool

    public var isActive: Bool {
        releasedAt == nil
    }

    public var isReady: Bool {
        isActive && !recoveryPending
    }

    public init(
        token: DatabaseRuntimeOwnerToken,
        claimedAt: Date,
        releasedAt: Date? = nil,
        recoveryPending: Bool = false
    ) {
        self.token = token
        self.claimedAt = claimedAt
        self.releasedAt = releasedAt
        self.recoveryPending = recoveryPending
    }
}

public struct DatabaseRuntimeRecoveryResult: Codable, Hashable, Sendable {
    public let inspectedOperationCount: Int
    public let recoveredOperationCount: Int
    public let hasMore: Bool

    public init(
        inspectedOperationCount: Int,
        recoveredOperationCount: Int,
        hasMore: Bool
    ) {
        self.inspectedOperationCount = inspectedOperationCount
        self.recoveredOperationCount = recoveredOperationCount
        self.hasMore = hasMore
    }
}

public struct DatabaseRuntimeOwnerClaimResult: Codable, Hashable, Sendable {
    public let owner: DatabaseRuntimeOwnerRecord
    public let retiredOwner: DatabaseRuntimeOwnerToken?
    public let recovery: DatabaseRuntimeRecoveryResult

    public init(
        owner: DatabaseRuntimeOwnerRecord,
        retiredOwner: DatabaseRuntimeOwnerToken? = nil,
        recovery: DatabaseRuntimeRecoveryResult
    ) {
        self.owner = owner
        self.retiredOwner = retiredOwner
        self.recovery = recovery
    }
}

public struct DatabaseMetadataCleanupResult: Codable, Hashable, Sendable {
    public let removedCount: Int
    public let hasMore: Bool

    public init(removedCount: Int, hasMore: Bool) {
        self.removedCount = removedCount
        self.hasMore = hasMore
    }
}

public enum DatabaseMetadataMaintenanceBounds {
    public static let maximumBatchSize = 100
}

public enum DatabaseMetadataStoreError: Error, Equatable, Sendable {
    case invalidLimit(Int)
    case invalidOffset(Int)
    case valueTooLarge(name: String, bytes: Int, maximum: Int)
    case invalidValue(name: String)
    case connectionNotFound(DatabaseConnectionID)
    case savedQueryNotFound(DatabaseSavedQueryID)
    case runtimeOwnerNotActive
    case corruptedRecord(kind: String, identifier: String)
}

public enum DatabaseOwnedOperationReservationResult: String, Codable, Hashable, Sendable {
    case reserved
    case operationIdentifierExists
    case connectionChangedOrMissing
    case runtimeOwnerNotActive
}

public enum DatabaseOwnedMetadataWriteResult: String, Codable, Hashable, Sendable {
    case saved
    case identifierExists
    case resourceMissing
    case resourceChanged
    case incompatibleSavedQueries
    case referencedConnectionChangedOrMissing
    case runtimeOwnerNotActive
}

public enum DatabaseOwnedMetadataDeleteResult: String, Codable, Hashable, Sendable {
    case deleted
    case notFound
    case runtimeOwnerNotActive
}

public enum DatabaseMutationOutcomeState: String, CaseIterable, Codable, Hashable, Sendable {
    case unknown
    case accepted
    case applied
    case notApplied
    case partiallyApplied
}

public enum DatabaseMutationOutcomeTransitionResult: String, Codable, Hashable, Sendable {
    case transitioned
    case unchanged
    case outcomeNotFound
    case invalidTransition
    case runtimeOwnerNotActive
}

public protocol DatabaseMetadataStore: Sendable {
    func saveConnection(
        _ definition: DatabaseConnectionDefinition,
        replacing expected: DatabaseConnectionDefinition?,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedMetadataWriteResult
    func connection(id: DatabaseConnectionID) async throws -> DatabaseConnectionDefinition?
    func connections(matching search: DatabaseConnectionSearch) async throws
        -> [DatabaseConnectionDefinition]
    func deleteConnection(
        id: DatabaseConnectionID,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedMetadataDeleteResult
    func saveQuery(
        _ query: DatabaseSavedQuery,
        replacing expected: DatabaseSavedQuery?,
        validatedAgainst connection: DatabaseConnectionDefinition?,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedMetadataWriteResult
    func savedQuery(id: DatabaseSavedQueryID) async throws -> DatabaseSavedQuery?
    func savedQueries(matching search: DatabaseSavedQuerySearch) async throws
        -> [DatabaseSavedQuery]
    func deleteSavedQuery(
        id: DatabaseSavedQueryID,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedMetadataDeleteResult
    func runtimeOwner() async throws -> DatabaseRuntimeOwnerRecord?
    func claimRuntimeOwner(
        claimedAt: Date,
        recoveryLimit: Int
    ) async throws -> DatabaseRuntimeOwnerClaimResult
    func recoverRuntimeOwner(
        _ owner: DatabaseRuntimeOwnerToken,
        limit: Int
    ) async throws -> DatabaseRuntimeRecoveryResult
    func releaseRuntimeOwner(
        _ token: DatabaseRuntimeOwnerToken,
        releasedAt: Date
    ) async throws -> Bool
    func reserveOperation(
        _ summary: DatabaseOperationRecordSummary,
        for connection: DatabaseConnectionDefinition,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedOperationReservationResult
    func reserveEphemeralOperation(
        _ summary: DatabaseOperationRecordSummary,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedOperationReservationResult
    func transitionOperation(
        _ summary: DatabaseOperationRecordSummary,
        from expectedStates: Set<DatabaseOperationState>,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> Bool
    func operation(id: DatabaseOperationID) async throws -> DatabaseOperationRecordSummary?
    func operations(matching search: DatabaseOperationHistorySearch) async throws
        -> [DatabaseOperationRecordSummary]
    func recordMutationOutcome(
        _ outcome: DatabaseMutationApplyResult,
        operationID: DatabaseOperationID,
        owner: DatabaseRuntimeOwnerToken
    ) async throws
    func transitionMutationOutcome(
        _ outcome: DatabaseMutationApplyResult,
        operationID: DatabaseOperationID,
        from expectedStates: Set<DatabaseMutationOutcomeState>,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseMutationOutcomeTransitionResult
    func mutationOutcome(
        operationID: DatabaseOperationID
    ) async throws -> DatabaseMutationApplyResult?
    func pruneOperations(
        finishedBefore date: Date,
        limit: Int,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseMetadataCleanupResult
    func registerConfirmation(
        _ receipt: DatabaseConfirmationReceipt,
        owner: DatabaseRuntimeOwnerToken
    ) async throws
    func consumeConfirmation(
        identifier: UUID,
        effectDigest: String,
        connection: DatabaseConnectionDefinition,
        consumedAt: Date,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> Bool
    func removeExpiredConfirmations(
        before date: Date,
        limit: Int,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseMetadataCleanupResult
}

extension DatabaseMutationApplyResult {
    var outcomeState: DatabaseMutationOutcomeState {
        if disposition == .accepted {
            return .accepted
        }
        switch effect {
        case .applied:
            return .applied
        case .notApplied:
            return .notApplied
        case .partiallyApplied:
            return .partiallyApplied
        case .unknown:
            return .unknown
        }
    }
}

enum DatabaseRuntimeOwnerFactory {
    static func claimReadyOwner(
        from store: any DatabaseMetadataStore,
        claimedAt: Date,
        recoveryLimit: Int = DatabaseMetadataMaintenanceBounds.maximumBatchSize
    ) async throws -> DatabaseRuntimeOwnerClaimResult {
        var claim = try await store.claimRuntimeOwner(
            claimedAt: claimedAt,
            recoveryLimit: recoveryLimit)
        if let retiredOwner = claim.retiredOwner {
            await DatabaseExecutor.retireRuntimeOwnerCoordination(retiredOwner)
        }
        var inspected = claim.recovery.inspectedOperationCount
        var recovered = claim.recovery.recoveredOperationCount
        while claim.recovery.hasMore {
            let recovery = try await store.recoverRuntimeOwner(
                claim.owner.token,
                limit: recoveryLimit)
            inspected += recovery.inspectedOperationCount
            recovered += recovery.recoveredOperationCount
            claim = DatabaseRuntimeOwnerClaimResult(
                owner: DatabaseRuntimeOwnerRecord(
                    token: claim.owner.token,
                    claimedAt: claim.owner.claimedAt,
                    recoveryPending: recovery.hasMore),
                retiredOwner: claim.retiredOwner,
                recovery: DatabaseRuntimeRecoveryResult(
                    inspectedOperationCount: inspected,
                    recoveredOperationCount: recovered,
                    hasMore: recovery.hasMore))
        }
        return claim
    }
}
