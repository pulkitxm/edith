import EdithDatabase
import Foundation
import Testing

@Suite struct SQLiteDatabaseMetadataStoreTests {
    @Test func createsVersionedWALStoreAndPersistsConnections() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDatabaseMetadataStore(path: path)
        let diagnostics = try await store.diagnostics()
        #expect(diagnostics.schemaVersion == SQLiteDatabaseMetadataStore.schemaVersion)
        #expect(diagnostics.journalMode == "wal")
        #expect(diagnostics.foreignKeysEnabled)

        let connection = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "8C808A08-F04C-4127-B088-6E50DFF89911")!,
            name: "Orders",
            group: "Commerce",
            tags: ["Critical", "Orders"],
            isFavorite: true,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            lastUsedAt: Date(timeIntervalSince1970: 300))
        try await store.saveConnection(connection)
        #expect(try await store.connection(id: connection.id) == connection)

        let reopened = try SQLiteDatabaseMetadataStore(path: path)
        #expect(try await reopened.connection(id: connection.id) == connection)
        #expect(try await reopened.deleteConnection(id: connection.id))
        #expect(try await store.connection(id: connection.id) == nil)
        #expect(try await store.deleteConnection(id: connection.id) == false)
    }

    @Test func filtersConnectionsWithStableServerSideOrdering() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDatabaseMetadataStore(path: path)
        let orders = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "E8B03511-1444-4E85-AD4B-F2B20D699C1B")!,
            name: "Orders 100%",
            environment: .production,
            group: "Commerce",
            tags: ["Critical", "Orders"],
            isFavorite: true,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            lastUsedAt: Date(timeIntervalSince1970: 300))
        let cache = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "026788AF-45E6-4818-A981-C36C1737B9BF")!,
            name: "Orders Cache",
            product: .redis,
            environment: .staging,
            group: "Commerce",
            tags: ["orders", "cache"],
            createdAt: Date(timeIntervalSince1970: 110),
            updatedAt: Date(timeIntervalSince1970: 250),
            lastUsedAt: Date(timeIntervalSince1970: 400))
        let analytics = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "9BC3FAB1-DA05-44B6-9001-F5E21F4139C4")!,
            name: "Analytics",
            product: .clickHouse,
            group: "Insights",
            tags: ["warehouse"],
            createdAt: Date(timeIntervalSince1970: 120),
            updatedAt: Date(timeIntervalSince1970: 500))
        try await store.saveConnection(orders)
        try await store.saveConnection(cache)
        try await store.saveConnection(analytics)

        let recent = try await store.connections(matching: DatabaseConnectionSearch(limit: 10))
        #expect(recent.map(\.id) == [cache.id, orders.id, analytics.id])
        let tagged = try await store.connections(
            matching: DatabaseConnectionSearch(
                text: "orders",
                products: [.postgresql, .redis],
                group: "Commerce",
                tags: ["ORDERS"],
                order: .name,
                limit: 10))
        #expect(tagged.map(\.id) == [orders.id, cache.id])
        let literalPercent = try await store.connections(
            matching: DatabaseConnectionSearch(text: "%", limit: 10))
        #expect(literalPercent.map(\.id) == [orders.id])
        let favoriteProduction = try await store.connections(
            matching: DatabaseConnectionSearch(
                environments: [.production],
                favoritesOnly: true,
                limit: 10))
        #expect(favoriteProduction.map(\.id) == [orders.id])
    }

    @Test func savesFiltersAndDeletesQueriesWithoutLoadingUnboundedResults() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDatabaseMetadataStore(path: path)
        let connection = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "B488E11D-ACB3-4DE2-991F-C617335A1546")!,
            name: "Orders",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20))
        try await store.saveConnection(connection)
        let oldQuery = DatabasePersistenceFixtures.savedQuery(
            id: UUID(uuidString: "39EA90E4-FE96-4632-B307-56C73AC76569")!,
            connectionID: connection.id,
            name: "Recent orders",
            language: .sql,
            text: "SELECT id FROM orders ORDER BY id DESC LIMIT 200",
            tags: ["Orders", "Read"],
            isFavorite: true,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 150))
        let newQuery = DatabasePersistenceFixtures.savedQuery(
            id: UUID(uuidString: "C01EA4DC-5352-4A82-B25A-1EC90785BE78")!,
            name: "Cache scan",
            language: .redisCommand,
            text: "SCAN 0 MATCH order:* COUNT 200",
            tags: ["Orders", "Cache"],
            createdAt: Date(timeIntervalSince1970: 110),
            updatedAt: Date(timeIntervalSince1970: 250))
        try await store.saveQuery(oldQuery)
        try await store.saveQuery(newQuery)
        #expect(try await store.savedQuery(id: oldQuery.id) == oldQuery)

        let filtered = try await store.savedQueries(
            matching: DatabaseSavedQuerySearch(
                text: "recent",
                connectionID: connection.id,
                languages: [.sql],
                tags: ["READ"],
                favoritesOnly: true,
                limit: 10))
        #expect(filtered == [oldQuery])
        let paged = try await store.savedQueries(
            matching: DatabaseSavedQuerySearch(order: .recentlyUpdated, limit: 1, offset: 1))
        #expect(paged == [oldQuery])
        #expect(try await store.deleteConnection(id: connection.id))
        #expect(try await store.savedQuery(id: oldQuery.id) == oldQuery)
        #expect(try await store.deleteSavedQuery(id: oldQuery.id))
        #expect(try await store.savedQuery(id: oldQuery.id) == nil)
    }

    @Test func updatesFiltersAndPrunesBoundedOperationHistory() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDatabaseMetadataStore(path: path)
        let connection = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "E1B0A3CA-EB84-40A7-847B-A3E1375CD02A")!,
            name: "Orders",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20))
        let runningID = UUID(uuidString: "8627F4BA-1140-45F4-A6D1-08042697E779")!
        let running = DatabasePersistenceFixtures.operation(
            id: runningID,
            connection: connection,
            kind: "browse",
            state: .running,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil)
        let failed = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "B35DF930-5F00-4502-8EE7-36D2A3702B73")!,
            connection: connection,
            kind: "export",
            state: .failed,
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 250))
        try await store.recordOperation(running)
        try await store.recordOperation(failed)
        let succeeded = DatabasePersistenceFixtures.operation(
            id: runningID,
            connection: connection,
            kind: "browse",
            state: .succeeded,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 150))
        try await store.recordOperation(succeeded)
        #expect(try await store.operation(id: succeeded.id) == succeeded)

        let filtered = try await store.operations(
            matching: DatabaseOperationHistorySearch(
                connectionID: connection.id,
                states: [.failed],
                kinds: ["export"],
                limit: 10))
        #expect(filtered == [failed])
        #expect(
            try await store.pruneOperations(finishedBefore: Date(timeIntervalSince1970: 200)) == 1)
        #expect(try await store.operation(id: succeeded.id) == nil)
        #expect(try await store.operation(id: failed.id) == failed)
    }

    @Test func atomicallyConsumesCrossInstanceConfirmationReceiptsOnce() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try SQLiteDatabaseMetadataStore(path: path)
        let secondStore = try SQLiteDatabaseMetadataStore(path: path)
        let connection = try DatabasePersistenceFixtures.connection(
            id: DatabaseConnectionFixtures.connectionID.rawValue,
            name: "Confirmation",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200))
        try await firstStore.saveConnection(connection)
        let identifier = UUID(uuidString: "006EA1D4-742C-459A-BC6A-67F579B63CE8")!
        try await firstStore.registerConfirmation(
            DatabaseConfirmationReceipt(
                identifier: identifier,
                effectDigest: "effect-a",
                expiresAt: Date(timeIntervalSince1970: 500)))
        async let first = firstStore.consumeConfirmation(
            identifier: identifier,
            effectDigest: "effect-a",
            connection: connection,
            consumedAt: Date(timeIntervalSince1970: 400))
        async let second = secondStore.consumeConfirmation(
            identifier: identifier,
            effectDigest: "effect-a",
            connection: connection,
            consumedAt: Date(timeIntervalSince1970: 400))
        let results = try await [first, second]
        #expect(results.filter { $0 }.count == 1)
        #expect(
            try await firstStore.consumeConfirmation(
                identifier: identifier,
                effectDigest: "effect-a",
                connection: connection,
                consumedAt: Date(timeIntervalSince1970: 410)) == false)

        let expiredID = UUID(uuidString: "29C07BC9-7472-4EDB-8F58-1974E9F3BD02")!
        try await firstStore.registerConfirmation(
            DatabaseConfirmationReceipt(
                identifier: expiredID,
                effectDigest: "effect-b",
                expiresAt: Date(timeIntervalSince1970: 300)))
        #expect(
            try await secondStore.consumeConfirmation(
                identifier: expiredID,
                effectDigest: "effect-b",
                connection: connection,
                consumedAt: Date(timeIntervalSince1970: 400)) == false)
        #expect(
            try await secondStore.removeExpiredConfirmations(
                before: Date(timeIntervalSince1970: 400)) == 1)
    }

    @Test func rejectsUnboundedAndOversizedMetadataRequests() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDatabaseMetadataStore(path: path)
        await #expect(throws: DatabaseMetadataStoreError.invalidLimit(0)) {
            _ = try await store.connections(matching: DatabaseConnectionSearch(limit: 0))
        }
        await #expect(throws: DatabaseMetadataStoreError.invalidOffset(-1)) {
            _ = try await store.savedQueries(matching: DatabaseSavedQuerySearch(offset: -1))
        }
        let query = DatabasePersistenceFixtures.savedQuery(
            id: UUID(),
            name: "Large",
            language: .sql,
            text: String(repeating: "x", count: SQLiteDatabaseMetadataStore.maximumQueryBytes + 1),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20))
        await #expect(
            throws: DatabaseMetadataStoreError.valueTooLarge(
                name: "saved query text",
                bytes: SQLiteDatabaseMetadataStore.maximumQueryBytes + 1,
                maximum: SQLiteDatabaseMetadataStore.maximumQueryBytes)
        ) {
            try await store.saveQuery(query)
        }
    }
}
