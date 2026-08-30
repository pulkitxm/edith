import Foundation
import GRDB

public struct DatabaseMetadataDiagnostics: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let journalMode: String
    public let foreignKeysEnabled: Bool

    public init(schemaVersion: Int, journalMode: String, foreignKeysEnabled: Bool) {
        self.schemaVersion = schemaVersion
        self.journalMode = journalMode
        self.foreignKeysEnabled = foreignKeysEnabled
    }
}

public actor SQLiteDatabaseMetadataStore: DatabaseMetadataStore {
    public static let schemaVersion = 3
    public static let maximumConnectionCount = 500
    public static let maximumSavedQueryCount = 500
    public static let maximumHistoryCount = 1_000
    public static let maximumSearchOffset = 1_000_000
    public static let maximumNameBytes = 512
    public static let maximumQueryBytes = 8 * 1_024 * 1_024
    public static let maximumTagCount = 64
    public static let maximumTagBytes = 128
    private let pool: DatabasePool

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
        pool = try DatabasePool(path: path, configuration: configuration)
        try Self.migrator.migrate(pool)
    }

    public func diagnostics() throws -> DatabaseMetadataDiagnostics {
        try pool.read { database in
            let schemaVersion = try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0
            let journalMode = try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? ""
            let foreignKeys = try Int.fetchOne(database, sql: "PRAGMA foreign_keys") ?? 0
            return DatabaseMetadataDiagnostics(
                schemaVersion: schemaVersion,
                journalMode: journalMode.lowercased(),
                foreignKeysEnabled: foreignKeys == 1)
        }
    }

    public func saveConnection(
        _ definition: DatabaseConnectionDefinition,
        replacing expected: DatabaseConnectionDefinition?,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedMetadataWriteResult {
        guard expected?.id == nil || expected?.id == definition.id else {
            throw DatabaseMetadataStoreError.invalidValue(name: "expected connection identifier")
        }
        let prepared = try Self.prepareConnection(definition)
        let expectedData = try expected.map { try Self.encoder().encode($0) }
        try Task.checkCancellation()
        return try await pool.write { database in
            try Task.checkCancellation()
            guard try Self.isRuntimeOwnerActive(owner, in: database) else {
                return .runtimeOwnerNotActive
            }
            let storedData = try Data.fetchOne(
                database,
                sql: "SELECT definition FROM database_connections WHERE id = ?",
                arguments: [definition.id.rawValue.uuidString])
            if let expected, let expectedData {
                guard let storedData else { return .resourceMissing }
                guard storedData == expectedData else { return .resourceChanged }
                if expected.productHint != definition.productHint,
                    try Self.hasIncompatibleSavedQueries(
                        connectionID: definition.id,
                        product: definition.productHint,
                        in: database)
                {
                    return .incompatibleSavedQueries
                }
            } else if storedData != nil {
                return .identifierExists
            }
            try Task.checkCancellation()
            try Self.writeConnection(prepared, to: database)
            return .saved
        }
    }

    public func connection(id: DatabaseConnectionID) throws -> DatabaseConnectionDefinition? {
        try pool.read { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, display_name, product, environment, group_name, is_favorite,
                            created_at, updated_at, last_used_at, definition
                        FROM database_connections
                        WHERE id = ?
                        """,
                    arguments: [id.rawValue.uuidString])
            else {
                return nil
            }
            return try Self.decodeConnection(row, expectedID: id)
        }
    }

    public func connections(matching search: DatabaseConnectionSearch) throws
        -> [DatabaseConnectionDefinition]
    {
        try Self.validatePage(limit: search.limit, maximum: Self.maximumConnectionCount)
        try Self.validateOffset(search.offset)
        var clauses: [String] = []
        var arguments: [String: (any DatabaseValueConvertible)?] = [
            "limit": search.limit,
            "offset": search.offset,
        ]
        if let text = try Self.normalizedSearch(search.text) {
            clauses.append("LOWER(display_name) LIKE :search ESCAPE '\\'")
            arguments["search"] = "%\(Self.escapedLike(text))%"
        }
        if !search.products.isEmpty {
            clauses.append(
                Self.inClause(
                    column: "product",
                    prefix: "product",
                    values: search.products.map(\.rawValue),
                    arguments: &arguments))
        }
        if !search.environments.isEmpty {
            clauses.append(
                Self.inClause(
                    column: "environment",
                    prefix: "environment",
                    values: search.environments.map(\.rawValue),
                    arguments: &arguments))
        }
        if let group = search.group {
            clauses.append("group_name = :group_name")
            arguments["group_name"] = group
        }
        if search.favoritesOnly {
            clauses.append("is_favorite = 1")
        }
        for (index, tag) in try Self.normalizedTags(Array(search.tags)).enumerated() {
            let name = "tag_\(index)"
            clauses.append(
                "EXISTS (SELECT 1 FROM database_connection_tags t WHERE t.connection_id = database_connections.id AND t.tag = :\(name))"
            )
            arguments[name] = tag
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
        let sql = """
            SELECT id, display_name, product, environment, group_name, is_favorite,
                created_at, updated_at, last_used_at, definition
            FROM database_connections
            \(whereClause)
            ORDER BY \(Self.connectionOrder(search.order))
            LIMIT :limit OFFSET :offset
            """
        return try pool.read { database in
            try Row.fetchAll(database, sql: sql, arguments: StatementArguments(arguments)).map {
                try Self.decodeConnection($0)
            }
        }
    }

    public func deleteConnection(
        id: DatabaseConnectionID,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedMetadataDeleteResult {
        try Task.checkCancellation()
        return try await pool.write { database in
            try Task.checkCancellation()
            guard try Self.isRuntimeOwnerActive(owner, in: database) else {
                return .runtimeOwnerNotActive
            }
            try Task.checkCancellation()
            try database.execute(
                sql: "DELETE FROM database_connections WHERE id = ?",
                arguments: [id.rawValue.uuidString])
            return database.changesCount == 1 ? .deleted : .notFound
        }
    }

    public func saveQuery(
        _ query: DatabaseSavedQuery,
        replacing expected: DatabaseSavedQuery?,
        validatedAgainst connection: DatabaseConnectionDefinition?,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedMetadataWriteResult {
        guard expected?.id == nil || expected?.id == query.id else {
            throw DatabaseMetadataStoreError.invalidValue(name: "expected saved query identifier")
        }
        let prepared = try Self.prepareSavedQuery(query)
        let expectedData = try expected.map { try Self.encoder().encode($0) }
        let connectionData = try connection.map { try Self.encoder().encode($0) }
        try Task.checkCancellation()
        return try await pool.write { database in
            try Task.checkCancellation()
            guard try Self.isRuntimeOwnerActive(owner, in: database) else {
                return .runtimeOwnerNotActive
            }
            let storedData = try Data.fetchOne(
                database,
                sql: "SELECT query FROM database_saved_queries WHERE id = ?",
                arguments: [query.id.rawValue.uuidString])
            if let expectedData {
                guard let storedData else { return .resourceMissing }
                guard storedData == expectedData else { return .resourceChanged }
            } else if storedData != nil {
                return .identifierExists
            }
            if let connectionID = query.connectionID {
                guard connection?.id == connectionID, let connectionData else {
                    return .referencedConnectionChangedOrMissing
                }
                let storedConnectionData = try Data.fetchOne(
                    database,
                    sql: "SELECT definition FROM database_connections WHERE id = ?",
                    arguments: [connectionID.rawValue.uuidString])
                guard storedConnectionData == connectionData else {
                    return .referencedConnectionChangedOrMissing
                }
            } else if connection != nil {
                return .referencedConnectionChangedOrMissing
            }
            try Task.checkCancellation()
            try Self.writeSavedQuery(prepared, to: database)
            return .saved
        }
    }

    public func savedQuery(id: DatabaseSavedQueryID) throws -> DatabaseSavedQuery? {
        try pool.read { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, connection_id, name, language, is_favorite,
                            created_at, updated_at, query
                        FROM database_saved_queries
                        WHERE id = ?
                        """,
                    arguments: [id.rawValue.uuidString])
            else {
                return nil
            }
            return try Self.decodeSavedQuery(row, expectedID: id)
        }
    }

    public func savedQueries(matching search: DatabaseSavedQuerySearch) throws
        -> [DatabaseSavedQuery]
    {
        try Self.validatePage(limit: search.limit, maximum: Self.maximumSavedQueryCount)
        try Self.validateOffset(search.offset)
        var clauses: [String] = []
        var arguments: [String: (any DatabaseValueConvertible)?] = [
            "limit": search.limit,
            "offset": search.offset,
        ]
        if let text = try Self.normalizedSearch(search.text) {
            clauses.append("LOWER(name) LIKE :search ESCAPE '\\'")
            arguments["search"] = "%\(Self.escapedLike(text))%"
        }
        if let connectionID = search.connectionID {
            clauses.append("connection_id = :connection_id")
            arguments["connection_id"] = connectionID.rawValue.uuidString
        }
        if !search.languages.isEmpty {
            clauses.append(
                Self.inClause(
                    column: "language",
                    prefix: "language",
                    values: search.languages.map(\.rawValue),
                    arguments: &arguments))
        }
        if search.favoritesOnly {
            clauses.append("is_favorite = 1")
        }
        for (index, tag) in try Self.normalizedTags(Array(search.tags)).enumerated() {
            let name = "tag_\(index)"
            clauses.append(
                "EXISTS (SELECT 1 FROM database_saved_query_tags t WHERE t.query_id = database_saved_queries.id AND t.tag = :\(name))"
            )
            arguments[name] = tag
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
        let sql = """
            SELECT id, connection_id, name, language, is_favorite,
                created_at, updated_at, query
            FROM database_saved_queries
            \(whereClause)
            ORDER BY \(Self.savedQueryOrder(search.order))
            LIMIT :limit OFFSET :offset
            """
        return try pool.read { database in
            try Row.fetchAll(database, sql: sql, arguments: StatementArguments(arguments)).map {
                try Self.decodeSavedQuery($0)
            }
        }
    }

    public func deleteSavedQuery(
        id: DatabaseSavedQueryID,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedMetadataDeleteResult {
        try Task.checkCancellation()
        return try await pool.write { database in
            try Task.checkCancellation()
            guard try Self.isRuntimeOwnerActive(owner, in: database) else {
                return .runtimeOwnerNotActive
            }
            try Task.checkCancellation()
            try database.execute(
                sql: "DELETE FROM database_saved_queries WHERE id = ?",
                arguments: [id.rawValue.uuidString])
            return database.changesCount == 1 ? .deleted : .notFound
        }
    }

    public func runtimeOwner() throws -> DatabaseRuntimeOwnerRecord? {
        try pool.read { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql:
                        "SELECT token, claimed_at, released_at, recovery_pending FROM database_runtime_owner WHERE singleton = 1"
                )
            else {
                return nil
            }
            return try Self.decodeRuntimeOwner(row)
        }
    }

    public func claimRuntimeOwner(
        claimedAt: Date,
        recoveryLimit: Int = DatabaseMetadataMaintenanceBounds.maximumBatchSize
    ) throws -> DatabaseRuntimeOwnerClaimResult {
        guard claimedAt.timeIntervalSince1970.isFinite else {
            throw DatabaseMetadataStoreError.invalidValue(name: "runtime owner claimed at")
        }
        try Self.validateMaintenanceLimit(recoveryLimit)
        let token = DatabaseRuntimeOwnerToken()
        return try pool.write { database in
            let retiredOwner: DatabaseRuntimeOwnerToken?
            if let retiredValue = try String.fetchOne(
                database,
                sql: "SELECT token FROM database_runtime_owner WHERE singleton = 1")
            {
                guard let retiredToken = UUID(uuidString: retiredValue) else {
                    throw DatabaseMetadataStoreError.corruptedRecord(
                        kind: "runtime owner",
                        identifier: retiredValue)
                }
                retiredOwner = DatabaseRuntimeOwnerToken(rawValue: retiredToken)
            } else {
                retiredOwner = nil
            }
            try database.execute(
                sql: """
                    INSERT INTO database_runtime_owner (
                        singleton, token, claimed_at, released_at, recovery_pending,
                        recovery_cursor, recovery_finished_at
                    ) VALUES (1, :token, :claimed_at, NULL, 1, NULL, :claimed_at)
                    ON CONFLICT(singleton) DO UPDATE SET
                        token = excluded.token,
                        claimed_at = excluded.claimed_at,
                        released_at = NULL,
                        recovery_pending = 1,
                        recovery_cursor = NULL,
                        recovery_finished_at = excluded.recovery_finished_at
                    """,
                arguments: [
                    "token": token.rawValue.uuidString,
                    "claimed_at": claimedAt.timeIntervalSince1970,
                ])
            let recovery = try Self.recoverRuntimeOwnerBatch(
                database,
                owner: token,
                limit: recoveryLimit)
            return DatabaseRuntimeOwnerClaimResult(
                owner: DatabaseRuntimeOwnerRecord(
                    token: token,
                    claimedAt: claimedAt,
                    recoveryPending: recovery.hasMore),
                retiredOwner: retiredOwner,
                recovery: recovery)
        }
    }

    public func recoverRuntimeOwner(
        _ owner: DatabaseRuntimeOwnerToken,
        limit: Int
    ) throws -> DatabaseRuntimeRecoveryResult {
        try Self.validateMaintenanceLimit(limit)
        return try pool.write { database in
            try Self.recoverRuntimeOwnerBatch(database, owner: owner, limit: limit)
        }
    }

    public func releaseRuntimeOwner(
        _ token: DatabaseRuntimeOwnerToken,
        releasedAt: Date
    ) throws -> Bool {
        guard releasedAt.timeIntervalSince1970.isFinite else {
            throw DatabaseMetadataStoreError.invalidValue(name: "runtime owner released at")
        }
        return try pool.write { database in
            guard
                let claimedAt = try Double.fetchOne(
                    database,
                    sql: """
                        SELECT claimed_at FROM database_runtime_owner
                        WHERE singleton = 1 AND token = ? AND released_at IS NULL
                        """,
                    arguments: [token.rawValue.uuidString])
            else {
                return false
            }
            guard releasedAt.timeIntervalSince1970 >= claimedAt else {
                throw DatabaseMetadataStoreError.invalidValue(name: "runtime owner released at")
            }
            try database.execute(
                sql: """
                    UPDATE database_runtime_owner
                    SET released_at = :released_at
                    WHERE singleton = 1 AND token = :token AND released_at IS NULL
                    """,
                arguments: [
                    "released_at": releasedAt.timeIntervalSince1970,
                    "token": token.rawValue.uuidString,
                ])
            return database.changesCount == 1
        }
    }

    #if DEBUG
    func seedOperationIfAbsent(
        _ summary: DatabaseOperationRecordSummary
    ) throws -> Bool {
        let data = try Self.encoder().encode(summary)
        return try pool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO database_operation_history (
                        id, connection_id, kind, state, started_at, finished_at, summary
                    ) VALUES (
                        :id, :connection_id, :kind, :state, :started_at, :finished_at, :summary
                    )
                    ON CONFLICT(id) DO NOTHING
                    """,
                arguments: [
                    "id": summary.id.rawValue.uuidString,
                    "connection_id": summary.connection.id.rawValue.uuidString,
                    "kind": summary.kind.rawValue,
                    "state": summary.state.rawValue,
                    "started_at": summary.startedAt?.timeIntervalSince1970,
                    "finished_at": summary.finishedAt?.timeIntervalSince1970,
                    "summary": data,
                ])
            return database.changesCount == 1
        }
    }

    func reserveSeededOperation(
        _ summary: DatabaseOperationRecordSummary,
        for connection: DatabaseConnectionDefinition
    ) throws -> DatabaseOwnedOperationReservationResult {
        guard summary.connection.id == connection.id else {
            throw DatabaseMetadataStoreError.invalidValue(name: "operation connection")
        }
        let summaryData = try Self.encoder().encode(summary)
        let connectionData = try Self.encoder().encode(connection)
        return try pool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO database_operation_history (
                        id, connection_id, kind, state, started_at, finished_at, summary
                    )
                    SELECT
                        :id, :connection_id, :kind, :state, :started_at, :finished_at, :summary
                    WHERE EXISTS (
                        SELECT 1 FROM database_connections
                        WHERE id = :connection_id AND definition = :definition
                    )
                    ON CONFLICT(id) DO NOTHING
                    """,
                arguments: [
                    "id": summary.id.rawValue.uuidString,
                    "connection_id": summary.connection.id.rawValue.uuidString,
                    "kind": summary.kind.rawValue,
                    "state": summary.state.rawValue,
                    "started_at": summary.startedAt?.timeIntervalSince1970,
                    "finished_at": summary.finishedAt?.timeIntervalSince1970,
                    "summary": summaryData,
                    "definition": connectionData,
                ])
            if database.changesCount == 1 {
                return .reserved
            }
            let operationExists =
                try Bool.fetchOne(
                    database,
                    sql: "SELECT EXISTS(SELECT 1 FROM database_operation_history WHERE id = ?)",
                    arguments: [summary.id.rawValue.uuidString]) ?? false
            return operationExists
                ? .operationIdentifierExists
                : .connectionChangedOrMissing
        }
    }
    #endif

    public func reserveOperation(
        _ summary: DatabaseOperationRecordSummary,
        for connection: DatabaseConnectionDefinition,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseOwnedOperationReservationResult {
        guard summary.connection.id == connection.id else {
            throw DatabaseMetadataStoreError.invalidValue(name: "operation connection")
        }
        let summaryData = try Self.encoder().encode(summary)
        let connectionData = try Self.encoder().encode(connection)
        return try pool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO database_operation_history (
                        id, connection_id, kind, state, started_at, finished_at, summary, owner_token
                    )
                    SELECT
                        :id, :connection_id, :kind, :state, :started_at, :finished_at, :summary,
                        :owner_token
                    WHERE EXISTS (
                        SELECT 1 FROM database_connections
                        WHERE id = :connection_id AND definition = :definition
                    ) AND EXISTS (
                        SELECT 1 FROM database_runtime_owner
                        WHERE singleton = 1 AND token = :owner_token
                            AND released_at IS NULL AND recovery_pending = 0
                    )
                    ON CONFLICT(id) DO NOTHING
                    """,
                arguments: [
                    "id": summary.id.rawValue.uuidString,
                    "connection_id": summary.connection.id.rawValue.uuidString,
                    "kind": summary.kind.rawValue,
                    "state": summary.state.rawValue,
                    "started_at": summary.startedAt?.timeIntervalSince1970,
                    "finished_at": summary.finishedAt?.timeIntervalSince1970,
                    "summary": summaryData,
                    "owner_token": owner.rawValue.uuidString,
                    "definition": connectionData,
                ])
            if database.changesCount == 1 {
                return .reserved
            }
            let operationExists =
                try Bool.fetchOne(
                    database,
                    sql: "SELECT EXISTS(SELECT 1 FROM database_operation_history WHERE id = ?)",
                    arguments: [summary.id.rawValue.uuidString]) ?? false
            if operationExists {
                return .operationIdentifierExists
            }
            let ownerIsActive =
                try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM database_runtime_owner
                            WHERE singleton = 1 AND token = ?
                                AND released_at IS NULL AND recovery_pending = 0
                        )
                        """,
                    arguments: [owner.rawValue.uuidString]) ?? false
            return ownerIsActive
                ? .connectionChangedOrMissing
                : .runtimeOwnerNotActive
        }
    }

    public func reserveEphemeralOperation(
        _ summary: DatabaseOperationRecordSummary,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseOwnedOperationReservationResult {
        let summaryData = try Self.encoder().encode(summary)
        return try pool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO database_operation_history (
                        id, connection_id, kind, state, started_at, finished_at, summary, owner_token
                    )
                    SELECT
                        :id, :connection_id, :kind, :state, :started_at, :finished_at, :summary,
                        :owner_token
                    WHERE EXISTS (
                        SELECT 1 FROM database_runtime_owner
                        WHERE singleton = 1 AND token = :owner_token
                            AND released_at IS NULL AND recovery_pending = 0
                    )
                    ON CONFLICT(id) DO NOTHING
                    """,
                arguments: [
                    "id": summary.id.rawValue.uuidString,
                    "connection_id": summary.connection.id.rawValue.uuidString,
                    "kind": summary.kind.rawValue,
                    "state": summary.state.rawValue,
                    "started_at": summary.startedAt?.timeIntervalSince1970,
                    "finished_at": summary.finishedAt?.timeIntervalSince1970,
                    "summary": summaryData,
                    "owner_token": owner.rawValue.uuidString,
                ])
            if database.changesCount == 1 {
                return .reserved
            }
            let operationExists =
                try Bool.fetchOne(
                    database,
                    sql: "SELECT EXISTS(SELECT 1 FROM database_operation_history WHERE id = ?)",
                    arguments: [summary.id.rawValue.uuidString]) ?? false
            if operationExists {
                return .operationIdentifierExists
            }
            return .runtimeOwnerNotActive
        }
    }

    public func transitionOperation(
        _ summary: DatabaseOperationRecordSummary,
        from expectedStates: Set<DatabaseOperationState>,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> Bool {
        guard
            !expectedStates.isEmpty,
            expectedStates.count <= DatabaseOperationState.allCases.count
        else {
            throw DatabaseMetadataStoreError.invalidValue(name: "operation expected states")
        }
        let data = try Self.encoder().encode(summary)
        var arguments: [String: (any DatabaseValueConvertible)?] = [
            "id": summary.id.rawValue.uuidString,
            "connection_id": summary.connection.id.rawValue.uuidString,
            "kind": summary.kind.rawValue,
            "state": summary.state.rawValue,
            "started_at": summary.startedAt?.timeIntervalSince1970,
            "finished_at": summary.finishedAt?.timeIntervalSince1970,
            "summary": data,
            "owner_token": owner.rawValue.uuidString,
        ]
        let expectedStatesClause = Self.inClause(
            column: "state",
            prefix: "expected_state",
            values: expectedStates.map(\.rawValue),
            arguments: &arguments)
        return try pool.write { database in
            try database.execute(
                sql: """
                    UPDATE database_operation_history
                    SET state = :state,
                        started_at = :started_at,
                        finished_at = :finished_at,
                        summary = :summary
                    WHERE id = :id
                        AND connection_id = :connection_id
                        AND kind = :kind
                        AND owner_token = :owner_token
                        AND \(expectedStatesClause)
                        AND EXISTS (
                            SELECT 1 FROM database_runtime_owner
                            WHERE singleton = 1
                                AND token = :owner_token
                                AND released_at IS NULL
                                AND recovery_pending = 0
                        )
                    """,
                arguments: StatementArguments(arguments))
            return database.changesCount == 1
        }
    }

    #if DEBUG
    func seedOperation(_ summary: DatabaseOperationRecordSummary) throws {
        let data = try Self.encoder().encode(summary)
        try pool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO database_operation_history (
                        id, connection_id, kind, state, started_at, finished_at, summary
                    ) VALUES (
                        :id, :connection_id, :kind, :state, :started_at, :finished_at, :summary
                    )
                    ON CONFLICT(id) DO UPDATE SET
                        connection_id = excluded.connection_id,
                        kind = excluded.kind,
                        state = excluded.state,
                        started_at = excluded.started_at,
                        finished_at = excluded.finished_at,
                        summary = excluded.summary
                    WHERE database_operation_history.owner_token IS NULL
                    """,
                arguments: [
                    "id": summary.id.rawValue.uuidString,
                    "connection_id": summary.connection.id.rawValue.uuidString,
                    "kind": summary.kind.rawValue,
                    "state": summary.state.rawValue,
                    "started_at": summary.startedAt?.timeIntervalSince1970,
                    "finished_at": summary.finishedAt?.timeIntervalSince1970,
                    "summary": data,
                ])
        }
    }
    #endif

    public func operation(id: DatabaseOperationID) throws -> DatabaseOperationRecordSummary? {
        try pool.read { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, connection_id, kind, state, started_at, finished_at, summary
                        FROM database_operation_history
                        WHERE id = ?
                        """,
                    arguments: [id.rawValue.uuidString])
            else {
                return nil
            }
            return try Self.decodeOperation(row, expectedID: id)
        }
    }

    public func operations(matching search: DatabaseOperationHistorySearch) throws
        -> [DatabaseOperationRecordSummary]
    {
        try Self.validatePage(limit: search.limit, maximum: Self.maximumHistoryCount)
        var clauses: [String] = []
        var arguments: [String: (any DatabaseValueConvertible)?] = ["limit": search.limit]
        if let connectionID = search.connectionID {
            clauses.append("connection_id = :connection_id")
            arguments["connection_id"] = connectionID.rawValue.uuidString
        }
        if !search.states.isEmpty {
            clauses.append(
                Self.inClause(
                    column: "state",
                    prefix: "state",
                    values: search.states.map(\.rawValue),
                    arguments: &arguments))
        }
        if !search.kinds.isEmpty {
            clauses.append(
                Self.inClause(
                    column: "kind",
                    prefix: "kind",
                    values: search.kinds.map(\.rawValue),
                    arguments: &arguments))
        }
        if let before = search.before {
            clauses.append("COALESCE(finished_at, started_at, 0) < :before")
            arguments["before"] = before.timeIntervalSince1970
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
        let sql = """
            SELECT id, connection_id, kind, state, started_at, finished_at, summary
            FROM database_operation_history
            \(whereClause)
            ORDER BY COALESCE(finished_at, started_at, 0) DESC, id ASC
            LIMIT :limit
            """
        return try pool.read { database in
            try Row.fetchAll(database, sql: sql, arguments: StatementArguments(arguments)).map {
                try Self.decodeOperation($0)
            }
        }
    }

    public func pruneOperations(
        finishedBefore date: Date,
        limit: Int = DatabaseMetadataMaintenanceBounds.maximumBatchSize,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseMetadataCleanupResult {
        try Self.validateMaintenance(date: date, limit: limit)
        return try pool.write { database in
            guard try Self.isRuntimeOwnerActive(owner, in: database) else {
                throw DatabaseMetadataStoreError.runtimeOwnerNotActive
            }
            try database.execute(
                sql: """
                    DELETE FROM database_operation_history
                    WHERE id IN (
                        SELECT id FROM database_operation_history
                        WHERE finished_at IS NOT NULL AND finished_at < :before
                        ORDER BY finished_at, id
                        LIMIT :limit
                    )
                    """,
                arguments: [
                    "before": date.timeIntervalSince1970,
                    "limit": limit,
                ])
            let removedCount = database.changesCount
            let hasMore =
                try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM database_operation_history
                            WHERE finished_at IS NOT NULL AND finished_at < ?
                        )
                        """,
                    arguments: [date.timeIntervalSince1970]) ?? false
            return DatabaseMetadataCleanupResult(
                removedCount: removedCount,
                hasMore: hasMore)
        }
    }

    public func registerConfirmation(
        _ receipt: DatabaseConfirmationReceipt,
        owner: DatabaseRuntimeOwnerToken
    ) throws {
        try pool.write { database in
            guard try Self.isRuntimeOwnerActive(owner, in: database) else {
                throw DatabaseMetadataStoreError.runtimeOwnerNotActive
            }
            try database.execute(
                sql: """
                    INSERT INTO database_confirmation_receipts (
                        id, effect_digest, expires_at, consumed_at
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    receipt.identifier.uuidString,
                    receipt.effectDigest,
                    receipt.expiresAt.timeIntervalSince1970,
                    receipt.consumedAt?.timeIntervalSince1970,
                ])
        }
    }

    public func consumeConfirmation(
        identifier: UUID,
        effectDigest: String,
        connection: DatabaseConnectionDefinition,
        consumedAt: Date,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> Bool {
        let definition = try Self.encoder().encode(connection)
        return try pool.write { database in
            guard try Self.isRuntimeOwnerActive(owner, in: database) else {
                throw DatabaseMetadataStoreError.runtimeOwnerNotActive
            }
            try database.execute(
                sql: """
                    UPDATE database_confirmation_receipts
                    SET consumed_at = :consumed_at
                    WHERE id = :id
                        AND effect_digest = :effect_digest
                        AND consumed_at IS NULL
                        AND expires_at > :consumed_at
                        AND EXISTS (
                            SELECT 1 FROM database_connections
                            WHERE id = :connection_id AND definition = :connection_definition
                        )
                    """,
                arguments: [
                    "consumed_at": consumedAt.timeIntervalSince1970,
                    "id": identifier.uuidString,
                    "effect_digest": effectDigest,
                    "connection_id": connection.id.rawValue.uuidString,
                    "connection_definition": definition,
                ])
            return database.changesCount == 1
        }
    }

    public func removeExpiredConfirmations(
        before date: Date,
        limit: Int = DatabaseMetadataMaintenanceBounds.maximumBatchSize,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseMetadataCleanupResult {
        try Self.validateMaintenance(date: date, limit: limit)
        return try pool.write { database in
            guard try Self.isRuntimeOwnerActive(owner, in: database) else {
                throw DatabaseMetadataStoreError.runtimeOwnerNotActive
            }
            try database.execute(
                sql: """
                    DELETE FROM database_confirmation_receipts
                    WHERE id IN (
                        SELECT id FROM database_confirmation_receipts
                        WHERE expires_at <= :before
                        ORDER BY expires_at, id
                        LIMIT :limit
                    )
                    """,
                arguments: [
                    "before": date.timeIntervalSince1970,
                    "limit": limit,
                ])
            let removedCount = database.changesCount
            let hasMore =
                try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM database_confirmation_receipts
                            WHERE expires_at <= ?
                        )
                        """,
                    arguments: [date.timeIntervalSince1970]) ?? false
            return DatabaseMetadataCleanupResult(
                removedCount: removedCount,
                hasMore: hasMore)
        }
    }

    #if DEBUG
    func seedConnection(_ definition: DatabaseConnectionDefinition) throws {
        let prepared = try Self.prepareConnection(definition)
        try pool.write { database in
            try Self.writeConnection(prepared, to: database)
        }
    }

    func removeSeededConnection(id: DatabaseConnectionID) throws -> Bool {
        try pool.write { database in
            try database.execute(
                sql: "DELETE FROM database_connections WHERE id = ?",
                arguments: [id.rawValue.uuidString])
            return database.changesCount == 1
        }
    }

    func seedSavedQuery(_ query: DatabaseSavedQuery) throws {
        let prepared = try Self.prepareSavedQuery(query)
        try pool.write { database in
            try Self.writeSavedQuery(prepared, to: database)
        }
    }

    func removeSeededSavedQuery(id: DatabaseSavedQueryID) throws -> Bool {
        try pool.write { database in
            try database.execute(
                sql: "DELETE FROM database_saved_queries WHERE id = ?",
                arguments: [id.rawValue.uuidString])
            return database.changesCount == 1
        }
    }

    func executeCorruptionSQLForTesting(_ sql: String) throws {
        try pool.write { database in
            try database.execute(sql: sql)
        }
    }
    #endif
}

extension SQLiteDatabaseMetadataStore {
    private struct PreparedConnection {
        let definition: DatabaseConnectionDefinition
        let tags: [String]
        let data: Data
    }

    private struct PreparedSavedQuery {
        let query: DatabaseSavedQuery
        let tags: [String]
        let data: Data
    }

    private static func prepareConnection(
        _ definition: DatabaseConnectionDefinition
    ) throws -> PreparedConnection {
        try validateName(definition.displayName, field: "connection name")
        return try PreparedConnection(
            definition: definition,
            tags: normalizedTags(definition.tags),
            data: encoder().encode(definition))
    }

    private static func prepareSavedQuery(
        _ query: DatabaseSavedQuery
    ) throws -> PreparedSavedQuery {
        try validateName(query.name, field: "saved query name")
        try validateSize(
            query.text,
            field: "saved query text",
            maximum: maximumQueryBytes)
        return try PreparedSavedQuery(
            query: query,
            tags: normalizedTags(query.tags),
            data: encoder().encode(query))
    }

    private static func writeConnection(
        _ prepared: PreparedConnection,
        to database: Database
    ) throws {
        let definition = prepared.definition
        try database.execute(
            sql: """
                INSERT INTO database_connections (
                    id, display_name, product, environment, group_name, is_favorite,
                    created_at, updated_at, last_used_at, definition
                ) VALUES (
                    :id, :display_name, :product, :environment, :group_name, :is_favorite,
                    :created_at, :updated_at, :last_used_at, :definition
                )
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    product = excluded.product,
                    environment = excluded.environment,
                    group_name = excluded.group_name,
                    is_favorite = excluded.is_favorite,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    last_used_at = excluded.last_used_at,
                    definition = excluded.definition
                """,
            arguments: [
                "id": definition.id.rawValue.uuidString,
                "display_name": definition.displayName,
                "product": definition.productHint.rawValue,
                "environment": definition.environment.kind.rawValue,
                "group_name": definition.group,
                "is_favorite": definition.isFavorite,
                "created_at": definition.createdAt.timeIntervalSince1970,
                "updated_at": definition.updatedAt.timeIntervalSince1970,
                "last_used_at": definition.lastUsedAt?.timeIntervalSince1970,
                "definition": prepared.data,
            ])
        try database.execute(
            sql: "DELETE FROM database_connection_tags WHERE connection_id = ?",
            arguments: [definition.id.rawValue.uuidString])
        for tag in prepared.tags {
            try database.execute(
                sql: "INSERT INTO database_connection_tags (connection_id, tag) VALUES (?, ?)",
                arguments: [definition.id.rawValue.uuidString, tag])
        }
    }

    private static func writeSavedQuery(
        _ prepared: PreparedSavedQuery,
        to database: Database
    ) throws {
        let query = prepared.query
        try database.execute(
            sql: """
                INSERT INTO database_saved_queries (
                    id, connection_id, name, language, is_favorite, created_at, updated_at, query
                ) VALUES (
                    :id, :connection_id, :name, :language, :is_favorite, :created_at, :updated_at, :query
                )
                ON CONFLICT(id) DO UPDATE SET
                    connection_id = excluded.connection_id,
                    name = excluded.name,
                    language = excluded.language,
                    is_favorite = excluded.is_favorite,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    query = excluded.query
                """,
            arguments: [
                "id": query.id.rawValue.uuidString,
                "connection_id": query.connectionID?.rawValue.uuidString,
                "name": query.name,
                "language": query.language.rawValue,
                "is_favorite": query.isFavorite,
                "created_at": query.createdAt.timeIntervalSince1970,
                "updated_at": query.updatedAt.timeIntervalSince1970,
                "query": prepared.data,
            ])
        try database.execute(
            sql: "DELETE FROM database_saved_query_tags WHERE query_id = ?",
            arguments: [query.id.rawValue.uuidString])
        for tag in prepared.tags {
            try database.execute(
                sql: "INSERT INTO database_saved_query_tags (query_id, tag) VALUES (?, ?)",
                arguments: [query.id.rawValue.uuidString, tag])
        }
    }

    private static func isRuntimeOwnerActive(
        _ owner: DatabaseRuntimeOwnerToken,
        in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM database_runtime_owner
                    WHERE singleton = 1 AND token = ?
                        AND released_at IS NULL AND recovery_pending = 0
                )
                """,
            arguments: [owner.rawValue.uuidString]) ?? false
    }

    private static func hasIncompatibleSavedQueries(
        connectionID: DatabaseConnectionID,
        product: DatabaseProduct,
        in database: Database
    ) throws -> Bool {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, connection_id, name, language, is_favorite,
                    created_at, updated_at, query
                FROM database_saved_queries
                WHERE connection_id = ?
                """,
            arguments: [connectionID.rawValue.uuidString])
        for row in rows {
            let query = try decodeSavedQuery(row)
            guard query.connectionID == connectionID else {
                throw DatabaseMetadataStoreError.corruptedRecord(
                    kind: "saved query",
                    identifier: query.id.rawValue.uuidString)
            }
            if !savedQueryLanguage(query.language, supports: product) {
                return true
            }
        }
        return false
    }

    private static func savedQueryLanguage(
        _ language: DatabaseSavedQueryLanguage,
        supports product: DatabaseProduct
    ) -> Bool {
        switch language {
        case .sql:
            product.family == .relational
        case .redisCommand:
            product.family == .keyValue
        case .mongoQuery:
            product.family == .document
        case .searchQueryDSL:
            product.family == .search
        case .clickHouseSQL:
            product == .clickHouse
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("database-metadata-v1") { database in
            try database.execute(
                sql: """
                    CREATE TABLE database_connections (
                        id TEXT PRIMARY KEY NOT NULL,
                        display_name TEXT NOT NULL,
                        product TEXT NOT NULL,
                        environment TEXT NOT NULL,
                        group_name TEXT,
                        is_favorite INTEGER NOT NULL CHECK (is_favorite IN (0, 1)),
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        last_used_at REAL,
                        definition BLOB NOT NULL
                    )
                    """)
            try database.execute(
                sql: """
                    CREATE TABLE database_connection_tags (
                        connection_id TEXT NOT NULL REFERENCES database_connections(id) ON DELETE CASCADE,
                        tag TEXT NOT NULL,
                        PRIMARY KEY (connection_id, tag)
                    ) WITHOUT ROWID
                    """)
            try database.execute(
                sql: """
                    CREATE TABLE database_saved_queries (
                        id TEXT PRIMARY KEY NOT NULL,
                        connection_id TEXT,
                        name TEXT NOT NULL,
                        language TEXT NOT NULL,
                        is_favorite INTEGER NOT NULL CHECK (is_favorite IN (0, 1)),
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        query BLOB NOT NULL
                    )
                    """)
            try database.execute(
                sql: """
                    CREATE TABLE database_saved_query_tags (
                        query_id TEXT NOT NULL REFERENCES database_saved_queries(id) ON DELETE CASCADE,
                        tag TEXT NOT NULL,
                        PRIMARY KEY (query_id, tag)
                    ) WITHOUT ROWID
                    """)
            try database.execute(
                sql: """
                    CREATE TABLE database_operation_history (
                        id TEXT PRIMARY KEY NOT NULL,
                        connection_id TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        state TEXT NOT NULL,
                        started_at REAL,
                        finished_at REAL,
                        summary BLOB NOT NULL
                    )
                    """)
            try database.execute(
                sql: """
                    CREATE TABLE database_confirmation_receipts (
                        id TEXT PRIMARY KEY NOT NULL,
                        effect_digest TEXT NOT NULL,
                        expires_at REAL NOT NULL,
                        consumed_at REAL
                    )
                    """)
            try database.execute(
                sql:
                    "CREATE INDEX database_connections_name ON database_connections(display_name COLLATE NOCASE, id)"
            )
            try database.execute(
                sql:
                    "CREATE INDEX database_connections_recent ON database_connections(last_used_at DESC, updated_at DESC, id)"
            )
            try database.execute(
                sql:
                    "CREATE INDEX database_saved_queries_recent ON database_saved_queries(updated_at DESC, id)"
            )
            try database.execute(
                sql:
                    "CREATE INDEX database_operation_history_recent ON database_operation_history(COALESCE(finished_at, started_at, 0) DESC, id)"
            )
            try database.execute(
                sql:
                    "CREATE INDEX database_confirmation_expiry ON database_confirmation_receipts(expires_at)"
            )
            try database.execute(sql: "PRAGMA user_version = 1")
        }
        migrator.registerMigration("database-metadata-v2") { database in
            try database.execute(
                sql: """
                    CREATE TABLE database_runtime_owner (
                        singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
                        token TEXT NOT NULL,
                        claimed_at REAL NOT NULL,
                        released_at REAL
                    )
                    """)
            try database.execute(
                sql: "ALTER TABLE database_operation_history ADD COLUMN owner_token TEXT")
            try database.execute(
                sql: """
                    CREATE INDEX database_operation_history_owner_state
                    ON database_operation_history(owner_token, state, id)
                    """)
            try database.execute(
                sql: """
                    CREATE INDEX database_operation_history_state
                    ON database_operation_history(state, id)
                    """)
            try database.execute(sql: "PRAGMA user_version = 2")
        }
        migrator.registerMigration("database-metadata-v3") { database in
            try database.execute(
                sql:
                    "ALTER TABLE database_runtime_owner ADD COLUMN recovery_pending INTEGER NOT NULL DEFAULT 0 CHECK (recovery_pending IN (0, 1))"
            )
            try database.execute(
                sql: "ALTER TABLE database_runtime_owner ADD COLUMN recovery_cursor TEXT")
            try database.execute(
                sql: "ALTER TABLE database_runtime_owner ADD COLUMN recovery_finished_at REAL")
            try database.execute(
                sql:
                    "CREATE INDEX database_operation_history_finished ON database_operation_history(finished_at, id)"
            )
            try database.execute(sql: "PRAGMA user_version = 3")
        }
        return migrator
    }

    private static func decodeRuntimeOwner(_ row: Row) throws -> DatabaseRuntimeOwnerRecord {
        let tokenValue: String = row["token"]
        guard let rawToken = UUID(uuidString: tokenValue) else {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "runtime owner",
                identifier: tokenValue)
        }
        let claimedAt: Double = row["claimed_at"]
        let releasedAt: Double? = row["released_at"]
        let recoveryPending: Bool = row["recovery_pending"]
        return DatabaseRuntimeOwnerRecord(
            token: DatabaseRuntimeOwnerToken(rawValue: rawToken),
            claimedAt: Date(timeIntervalSince1970: claimedAt),
            releasedAt: releasedAt.map(Date.init(timeIntervalSince1970:)),
            recoveryPending: recoveryPending)
    }

    private static func recoverRuntimeOwnerBatch(
        _ database: Database,
        owner: DatabaseRuntimeOwnerToken,
        limit: Int
    ) throws -> DatabaseRuntimeRecoveryResult {
        guard
            let ownerRow = try Row.fetchOne(
                database,
                sql: """
                    SELECT recovery_pending, recovery_cursor, recovery_finished_at
                    FROM database_runtime_owner
                    WHERE singleton = 1 AND token = ? AND released_at IS NULL
                    """,
                arguments: [owner.rawValue.uuidString])
        else {
            throw DatabaseMetadataStoreError.runtimeOwnerNotActive
        }
        let recoveryPending: Bool = ownerRow["recovery_pending"]
        guard recoveryPending else {
            return DatabaseRuntimeRecoveryResult(
                inspectedOperationCount: 0,
                recoveredOperationCount: 0,
                hasMore: false)
        }
        let cursor: String? = ownerRow["recovery_cursor"]
        guard let finishedAtValue: Double = ownerRow["recovery_finished_at"] else {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "runtime owner",
                identifier: owner.rawValue.uuidString)
        }
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, connection_id, kind, state, started_at, finished_at, summary
                FROM database_operation_history
                WHERE (:cursor IS NULL OR id > :cursor)
                ORDER BY id
                LIMIT :limit
                """,
            arguments: [
                "cursor": cursor,
                "limit": limit + 1,
            ])
        let inspectedRows = rows.prefix(limit)
        var recoveredOperationCount = 0
        for row in inspectedRows {
            let summary = try decodeOperation(row)
            guard [.queued, .running, .cancelling].contains(summary.state) else { continue }
            let finishedAt = Date(timeIntervalSince1970: finishedAtValue)
            let operationFinishedAt =
                summary.startedAt.map { max(finishedAt, $0) } ?? finishedAt
            let recovered = interruptedOperation(summary, finishedAt: operationFinishedAt)
            try database.execute(
                sql: """
                    UPDATE database_operation_history
                    SET state = :state, finished_at = :finished_at, summary = :summary
                    WHERE id = :id AND state = :expected_state AND summary = :expected_summary
                    """,
                arguments: [
                    "state": DatabaseOperationState.failed.rawValue,
                    "finished_at": operationFinishedAt.timeIntervalSince1970,
                    "summary": try encoder().encode(recovered),
                    "id": summary.id.rawValue.uuidString,
                    "expected_state": summary.state.rawValue,
                    "expected_summary": try encoder().encode(summary),
                ])
            guard database.changesCount == 1 else {
                throw DatabaseMetadataStoreError.corruptedRecord(
                    kind: "operation",
                    identifier: summary.id.rawValue.uuidString)
            }
            recoveredOperationCount += 1
        }
        let hasMore = rows.count > limit
        let nextCursor: String? = hasMore ? inspectedRows.last.map { $0["id"] } : nil
        try database.execute(
            sql: """
                UPDATE database_runtime_owner
                SET recovery_pending = :recovery_pending,
                    recovery_cursor = :recovery_cursor,
                    recovery_finished_at = CASE
                        WHEN :recovery_pending = 1 THEN recovery_finished_at
                        ELSE NULL
                    END
                WHERE singleton = 1 AND token = :token AND released_at IS NULL
                """,
            arguments: [
                "recovery_pending": hasMore,
                "recovery_cursor": nextCursor,
                "token": owner.rawValue.uuidString,
            ])
        guard database.changesCount == 1 else {
            throw DatabaseMetadataStoreError.runtimeOwnerNotActive
        }
        return DatabaseRuntimeRecoveryResult(
            inspectedOperationCount: inspectedRows.count,
            recoveredOperationCount: recoveredOperationCount,
            hasMore: hasMore)
    }

    private static func interruptedOperation(
        _ summary: DatabaseOperationRecordSummary,
        finishedAt: Date
    ) -> DatabaseOperationRecordSummary {
        DatabaseOperationRecordSummary(
            id: summary.id,
            kind: summary.kind,
            state: .failed,
            connection: summary.connection,
            target: summary.target,
            startedAt: summary.startedAt,
            finishedAt: finishedAt,
            deadline: summary.deadline,
            progress: summary.progress,
            cancellationSupport: summary.cancellationSupport,
            retryClassification: .userDecision,
            pageCount: summary.pageCount,
            recordCount: summary.recordCount,
            byteCount: summary.byteCount,
            warnings: summary.warnings,
            partialFailures: summary.partialFailures,
            error: DatabaseErrorEnvelope(
                category: .internalFailure,
                message: "The database runtime stopped before the operation completed.",
                productCode: "database.runtime.interrupted",
                retry: DatabaseRetryGuidance(
                    action: .userDecision,
                    message: "Review the operation state before deciding whether to retry.")))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    private static func validatePage(limit: Int, maximum: Int) throws {
        guard (1...maximum).contains(limit) else {
            throw DatabaseMetadataStoreError.invalidLimit(limit)
        }
    }

    private static func validateMaintenanceLimit(_ limit: Int) throws {
        try validatePage(
            limit: limit,
            maximum: DatabaseMetadataMaintenanceBounds.maximumBatchSize)
    }

    private static func validateMaintenance(date: Date, limit: Int) throws {
        guard date.timeIntervalSince1970.isFinite else {
            throw DatabaseMetadataStoreError.invalidValue(name: "maintenance date")
        }
        try validateMaintenanceLimit(limit)
    }

    private static func validateOffset(_ offset: Int) throws {
        guard (0...maximumSearchOffset).contains(offset) else {
            throw DatabaseMetadataStoreError.invalidOffset(offset)
        }
    }

    private static func validateName(_ value: String, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseMetadataStoreError.invalidValue(name: field)
        }
        try validateSize(value, field: field, maximum: maximumNameBytes)
    }

    private static func validateSize(_ value: String, field: String, maximum: Int) throws {
        let bytes = value.utf8.count
        guard bytes <= maximum else {
            throw DatabaseMetadataStoreError.valueTooLarge(
                name: field,
                bytes: bytes,
                maximum: maximum)
        }
    }

    private static func normalizedTags(_ tags: [String]) throws -> [String] {
        guard tags.count <= maximumTagCount else {
            throw DatabaseMetadataStoreError.valueTooLarge(
                name: "tag count",
                bytes: tags.count,
                maximum: maximumTagCount)
        }
        return try Set(
            tags.map { tag in
                let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else {
                    throw DatabaseMetadataStoreError.invalidValue(name: "tag")
                }
                try validateSize(normalized, field: "tag", maximum: maximumTagBytes)
                return normalized
            }
        ).sorted()
    }

    private static func normalizedSearch(_ text: String?) throws -> String? {
        guard let text else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        try validateSize(normalized, field: "search text", maximum: maximumNameBytes)
        return normalized
    }

    private static func escapedLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func inClause(
        column: String,
        prefix: String,
        values: [String],
        arguments: inout [String: (any DatabaseValueConvertible)?]
    ) -> String {
        let sortedValues = values.sorted()
        let placeholders = sortedValues.enumerated().map { index, value in
            let name = "\(prefix)_\(index)"
            arguments[name] = value
            return ":\(name)"
        }
        return "\(column) IN (\(placeholders.joined(separator: ", ")))"
    }

    private static func connectionOrder(_ order: DatabaseConnectionOrder) -> String {
        switch order {
        case .name:
            "display_name COLLATE NOCASE ASC, id ASC"
        case .recentlyUsed:
            "last_used_at IS NULL ASC, last_used_at DESC, updated_at DESC, id ASC"
        case .recentlyUpdated:
            "updated_at DESC, id ASC"
        case .recentlyCreated:
            "created_at DESC, id ASC"
        }
    }

    private static func savedQueryOrder(_ order: DatabaseSavedQueryOrder) -> String {
        switch order {
        case .name:
            "name COLLATE NOCASE ASC, id ASC"
        case .recentlyUpdated:
            "updated_at DESC, id ASC"
        case .recentlyCreated:
            "created_at DESC, id ASC"
        }
    }

    private static func decodeConnection(
        _ row: Row,
        expectedID: DatabaseConnectionID? = nil
    ) throws -> DatabaseConnectionDefinition {
        let identifierValue: String = row["id"]
        guard let rawIdentifier = UUID(uuidString: identifierValue) else {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "connection",
                identifier: identifierValue)
        }
        let identifier = DatabaseConnectionID(rawValue: rawIdentifier)
        let data: Data = row["definition"]
        let definition: DatabaseConnectionDefinition
        do {
            definition = try decoder().decode(DatabaseConnectionDefinition.self, from: data)
        } catch {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "connection",
                identifier: identifierValue)
        }
        let displayName: String = row["display_name"]
        let product: String = row["product"]
        let environment: String = row["environment"]
        let group: String? = row["group_name"]
        let isFavorite: Bool = row["is_favorite"]
        let createdAt: Double = row["created_at"]
        let updatedAt: Double = row["updated_at"]
        let lastUsedAt: Double? = row["last_used_at"]
        guard definition.id == identifier,
            expectedID.map({ $0 == identifier }) ?? true,
            definition.displayName == displayName,
            definition.productHint.rawValue == product,
            definition.environment.kind.rawValue == environment,
            definition.group == group,
            definition.isFavorite == isFavorite,
            definition.createdAt.timeIntervalSince1970 == createdAt,
            definition.updatedAt.timeIntervalSince1970 == updatedAt,
            definition.lastUsedAt?.timeIntervalSince1970 == lastUsedAt
        else {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "connection",
                identifier: identifierValue)
        }
        return definition
    }

    private static func decodeSavedQuery(
        _ row: Row,
        expectedID: DatabaseSavedQueryID? = nil
    ) throws -> DatabaseSavedQuery {
        let identifierValue: String = row["id"]
        guard let rawIdentifier = UUID(uuidString: identifierValue) else {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "saved query",
                identifier: identifierValue)
        }
        let identifier = DatabaseSavedQueryID(rawValue: rawIdentifier)
        let data: Data = row["query"]
        let query: DatabaseSavedQuery
        do {
            query = try decoder().decode(DatabaseSavedQuery.self, from: data)
        } catch {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "saved query",
                identifier: identifierValue)
        }
        let connectionIdentifierValue: String? = row["connection_id"]
        let connectionIdentifier: DatabaseConnectionID?
        if let connectionIdentifierValue {
            guard let rawConnectionIdentifier = UUID(uuidString: connectionIdentifierValue) else {
                throw DatabaseMetadataStoreError.corruptedRecord(
                    kind: "saved query",
                    identifier: identifierValue)
            }
            connectionIdentifier = DatabaseConnectionID(rawValue: rawConnectionIdentifier)
        } else {
            connectionIdentifier = nil
        }
        let name: String = row["name"]
        let language: String = row["language"]
        let isFavorite: Bool = row["is_favorite"]
        let createdAt: Double = row["created_at"]
        let updatedAt: Double = row["updated_at"]
        guard query.id == identifier,
            expectedID.map({ $0 == identifier }) ?? true,
            query.connectionID == connectionIdentifier,
            query.name == name,
            query.language.rawValue == language,
            query.isFavorite == isFavorite,
            query.createdAt.timeIntervalSince1970 == createdAt,
            query.updatedAt.timeIntervalSince1970 == updatedAt
        else {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "saved query",
                identifier: identifierValue)
        }
        return query
    }

    private static func decodeOperation(
        _ data: Data,
        id: DatabaseOperationID
    ) throws -> DatabaseOperationRecordSummary {
        let summary: DatabaseOperationRecordSummary
        do {
            summary = try decoder().decode(DatabaseOperationRecordSummary.self, from: data)
        } catch {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "operation",
                identifier: id.rawValue.uuidString)
        }
        guard summary.id == id else {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "operation",
                identifier: id.rawValue.uuidString)
        }
        return summary
    }

    private static func decodeOperation(
        _ row: Row,
        expectedID: DatabaseOperationID? = nil
    ) throws -> DatabaseOperationRecordSummary {
        let identifierValue: String = row["id"]
        guard let rawIdentifier = UUID(uuidString: identifierValue) else {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "operation",
                identifier: identifierValue)
        }
        let identifier = DatabaseOperationID(rawValue: rawIdentifier)
        let data: Data = row["summary"]
        let summary = try decodeOperation(data, id: identifier)
        let connectionIdentifierValue: String = row["connection_id"]
        guard let rawConnectionIdentifier = UUID(uuidString: connectionIdentifierValue) else {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "operation",
                identifier: identifierValue)
        }
        let kind: String = row["kind"]
        let state: String = row["state"]
        let startedAt: Double? = row["started_at"]
        let finishedAt: Double? = row["finished_at"]
        guard expectedID.map({ $0 == identifier }) ?? true,
            summary.connection.id.rawValue == rawConnectionIdentifier,
            summary.kind.rawValue == kind,
            summary.state.rawValue == state,
            summary.startedAt?.timeIntervalSince1970 == startedAt,
            summary.finishedAt?.timeIntervalSince1970 == finishedAt
        else {
            throw DatabaseMetadataStoreError.corruptedRecord(
                kind: "operation",
                identifier: identifierValue)
        }
        return summary
    }
}
