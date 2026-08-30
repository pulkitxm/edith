import Foundation
import Testing

@testable import EdithDatabase

private func databaseMetadataSQLiteBlob<Value: Encodable>(_ value: Value) throws -> String {
    try JSONEncoder().encode(value).map { String(format: "%02x", $0) }.joined()
}

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
        try await store.seedConnection(connection)
        #expect(try await store.connection(id: connection.id) == connection)

        let reopened = try SQLiteDatabaseMetadataStore(path: path)
        #expect(try await reopened.connection(id: connection.id) == connection)
        #expect(try await reopened.removeSeededConnection(id: connection.id))
        #expect(try await store.connection(id: connection.id) == nil)
        #expect(try await store.removeSeededConnection(id: connection.id) == false)
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
        try await store.seedConnection(orders)
        try await store.seedConnection(cache)
        try await store.seedConnection(analytics)

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
        try await store.seedConnection(connection)
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
        try await store.seedSavedQuery(oldQuery)
        try await store.seedSavedQuery(newQuery)
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
        #expect(try await store.removeSeededConnection(id: connection.id))
        #expect(try await store.savedQuery(id: oldQuery.id) == oldQuery)
        #expect(try await store.removeSeededSavedQuery(id: oldQuery.id))
        #expect(try await store.savedQuery(id: oldQuery.id) == nil)
    }

    @Test func updatesFiltersAndPrunesBoundedOperationHistory() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDatabaseMetadataStore(path: path)
        let owner = try await store.claimRuntimeOwner(
            claimedAt: Date(timeIntervalSince1970: 1)
        ).owner.token
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
        try await store.seedOperation(running)
        try await store.seedOperation(failed)
        let succeeded = DatabasePersistenceFixtures.operation(
            id: runningID,
            connection: connection,
            kind: "browse",
            state: .succeeded,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 150))
        try await store.seedOperation(succeeded)
        #expect(try await store.operation(id: succeeded.id) == succeeded)

        let filtered = try await store.operations(
            matching: DatabaseOperationHistorySearch(
                connectionID: connection.id,
                states: [.failed],
                kinds: ["export"],
                limit: 10))
        #expect(filtered == [failed])
        await #expect(throws: DatabaseMetadataStoreError.runtimeOwnerNotActive) {
            _ = try await store.pruneOperations(
                finishedBefore: Date(timeIntervalSince1970: 200),
                owner: DatabaseRuntimeOwnerToken())
        }
        #expect(try await store.operation(id: succeeded.id) == succeeded)
        #expect(
            try await store.pruneOperations(
                finishedBefore: Date(timeIntervalSince1970: 200),
                owner: owner) == 1)
        #expect(try await store.operation(id: succeeded.id) == nil)
        #expect(try await store.operation(id: failed.id) == failed)
    }

    @Test func atomicallyConsumesCrossInstanceConfirmationReceiptsOnce() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try SQLiteDatabaseMetadataStore(path: path)
        let secondStore = try SQLiteDatabaseMetadataStore(path: path)
        let owner = try await firstStore.claimRuntimeOwner(
            claimedAt: Date(timeIntervalSince1970: 1)
        ).owner.token
        let connection = try DatabasePersistenceFixtures.connection(
            id: DatabaseConnectionFixtures.connectionID.rawValue,
            name: "Confirmation",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200))
        try await firstStore.seedConnection(connection)
        let identifier = UUID(uuidString: "006EA1D4-742C-459A-BC6A-67F579B63CE8")!
        try await firstStore.registerConfirmation(
            DatabaseConfirmationReceipt(
                identifier: identifier,
                effectDigest: "effect-a",
                expiresAt: Date(timeIntervalSince1970: 500)),
            owner: owner)
        async let first = firstStore.consumeConfirmation(
            identifier: identifier,
            effectDigest: "effect-a",
            connection: connection,
            consumedAt: Date(timeIntervalSince1970: 400),
            owner: owner)
        async let second = secondStore.consumeConfirmation(
            identifier: identifier,
            effectDigest: "effect-a",
            connection: connection,
            consumedAt: Date(timeIntervalSince1970: 400),
            owner: owner)
        let results = try await [first, second]
        #expect(results.filter { $0 }.count == 1)
        #expect(
            try await firstStore.consumeConfirmation(
                identifier: identifier,
                effectDigest: "effect-a",
                connection: connection,
                consumedAt: Date(timeIntervalSince1970: 410),
                owner: owner) == false)

        let expiredID = UUID(uuidString: "29C07BC9-7472-4EDB-8F58-1974E9F3BD02")!
        try await firstStore.registerConfirmation(
            DatabaseConfirmationReceipt(
                identifier: expiredID,
                effectDigest: "effect-b",
                expiresAt: Date(timeIntervalSince1970: 300)),
            owner: owner)
        #expect(
            try await secondStore.consumeConfirmation(
                identifier: expiredID,
                effectDigest: "effect-b",
                connection: connection,
                consumedAt: Date(timeIntervalSince1970: 400),
                owner: owner) == false)
        #expect(
            try await secondStore.removeExpiredConfirmations(
                before: Date(timeIntervalSince1970: 400),
                owner: owner) == 1)
        _ = try await secondStore.claimRuntimeOwner(
            claimedAt: Date(timeIntervalSince1970: 500))
        await #expect(throws: DatabaseMetadataStoreError.runtimeOwnerNotActive) {
            try await firstStore.registerConfirmation(
                DatabaseConfirmationReceipt(
                    identifier: UUID(),
                    effectDigest: "stale",
                    expiresAt: Date(timeIntervalSince1970: 600)),
                owner: owner)
        }
        await #expect(throws: DatabaseMetadataStoreError.runtimeOwnerNotActive) {
            _ = try await firstStore.consumeConfirmation(
                identifier: identifier,
                effectDigest: "effect-a",
                connection: connection,
                consumedAt: Date(timeIntervalSince1970: 500),
                owner: owner)
        }
        await #expect(throws: DatabaseMetadataStoreError.runtimeOwnerNotActive) {
            _ = try await firstStore.removeExpiredConfirmations(
                before: Date(timeIntervalSince1970: 500),
                owner: owner)
        }
    }

    @Test func atomicallyReservesOperationIdentifiersAcrossStoreInstances() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try SQLiteDatabaseMetadataStore(path: path)
        let secondStore = try SQLiteDatabaseMetadataStore(path: path)
        let connection = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "35B60AB2-F238-445D-9C3E-C0654C78F19E")!,
            name: "Operations",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200))
        let operation = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "0578B2F9-4E59-4464-A2EA-AB8FA78D3C28")!,
            connection: connection,
            kind: .databaseConnectionTest,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 300),
            finishedAt: nil)

        async let first = firstStore.seedOperationIfAbsent(operation)
        async let second = secondStore.seedOperationIfAbsent(operation)
        let reservations = try await [first, second]

        #expect(reservations.filter { $0 }.count == 1)
        #expect(try await firstStore.operation(id: operation.id) == operation)
        #expect(try await secondStore.seedOperationIfAbsent(operation) == false)
    }

    @Test func operationReservationBindsTheExactSavedConnectionDefinition() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDatabaseMetadataStore(path: path)
        let connectionID = UUID(uuidString: "A74C3797-0FC1-4F52-B7DF-E63358DE5CA6")!
        let saved = try DatabasePersistenceFixtures.connection(
            id: connectionID,
            name: "Saved",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200))
        let stale = try DatabasePersistenceFixtures.connection(
            id: connectionID,
            name: "Stale",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200))
        try await store.seedConnection(saved)
        let first = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "A2D7474C-F123-4F9B-9798-F445F4C02D3C")!,
            connection: saved,
            kind: .databaseConnect,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 300),
            finishedAt: nil)

        #expect(try await store.reserveSeededOperation(first, for: saved) == .reserved)
        #expect(
            try await store.reserveSeededOperation(first, for: saved)
                == .operationIdentifierExists)

        let second = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "E4EB987F-E457-49B3-A8D4-13E685BF7414")!,
            connection: stale,
            kind: .databaseConnect,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 301),
            finishedAt: nil)
        #expect(
            try await store.reserveSeededOperation(second, for: stale)
                == .connectionChangedOrMissing)
        #expect(try await store.removeSeededConnection(id: saved.id))
        #expect(
            try await store.reserveSeededOperation(second, for: saved)
                == .connectionChangedOrMissing)
    }

    @Test func persistsRuntimeOwnerLifecycleAndOwnedReservationsAcrossStores() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try SQLiteDatabaseMetadataStore(path: path)
        let secondStore = try SQLiteDatabaseMetadataStore(path: path)
        let unownedToken = DatabaseRuntimeOwnerToken()
        let firstClaimedAt = Date(timeIntervalSince1970: 500)

        #expect(try await firstStore.runtimeOwner() == nil)
        await #expect(
            throws: DatabaseMetadataStoreError.invalidValue(
                name: "runtime owner claimed at")
        ) {
            _ = try await firstStore.claimRuntimeOwner(
                claimedAt: Date(timeIntervalSince1970: .infinity))
        }
        #expect(try await firstStore.runtimeOwner() == nil)
        let firstClaim = try await firstStore.claimRuntimeOwner(
            claimedAt: firstClaimedAt)
        let firstOwner = firstClaim.owner.token
        #expect(
            firstClaim
                == DatabaseRuntimeOwnerClaimResult(
                    owner: DatabaseRuntimeOwnerRecord(
                        token: firstOwner,
                        claimedAt: firstClaimedAt),
                    recoveredOperationCount: 0))
        #expect(try await secondStore.runtimeOwner() == firstClaim.owner)

        let connectionID = UUID(uuidString: "48CAEC19-E4CA-4EF9-9EA7-A17C5C2C650A")!
        let saved = try DatabasePersistenceFixtures.connection(
            id: connectionID,
            name: "Owned",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200))
        let stale = try DatabasePersistenceFixtures.connection(
            id: connectionID,
            name: "Stale",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200))
        try await firstStore.seedConnection(saved)
        let operation = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "FCEAA502-85AB-4919-955B-EE2776DBCC0D")!,
            connection: saved,
            kind: .databaseConnect,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 600),
            finishedAt: nil)

        #expect(
            try await firstStore.reserveOperation(operation, for: saved, owner: unownedToken)
                == .runtimeOwnerNotActive)
        let staleOperation = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "B1DB1C52-A615-4758-972D-52CA0B45FF94")!,
            connection: stale,
            kind: .databaseConnect,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 601),
            finishedAt: nil)
        #expect(
            try await firstStore.reserveOperation(staleOperation, for: stale, owner: firstOwner)
                == .connectionChangedOrMissing)

        async let firstReservation = firstStore.reserveOperation(
            operation,
            for: saved,
            owner: firstOwner)
        async let secondReservation = secondStore.reserveOperation(
            operation,
            for: saved,
            owner: firstOwner)
        let reservations = try await [firstReservation, secondReservation]
        #expect(reservations.filter { $0 == .reserved }.count == 1)
        #expect(reservations.filter { $0 == .operationIdentifierExists }.count == 1)

        await #expect(
            throws: DatabaseMetadataStoreError.invalidValue(
                name: "runtime owner released at")
        ) {
            _ = try await firstStore.releaseRuntimeOwner(
                firstOwner,
                releasedAt: Date(timeIntervalSince1970: .infinity))
        }
        await #expect(
            throws: DatabaseMetadataStoreError.invalidValue(
                name: "runtime owner released at")
        ) {
            _ = try await firstStore.releaseRuntimeOwner(
                firstOwner,
                releasedAt: Date(timeIntervalSince1970: 499))
        }
        #expect(try await secondStore.runtimeOwner()?.isActive == true)
        #expect(
            try await secondStore.releaseRuntimeOwner(
                unownedToken,
                releasedAt: Date(timeIntervalSince1970: 700)) == false)
        let releasedAt = Date(timeIntervalSince1970: 701)
        #expect(try await firstStore.releaseRuntimeOwner(firstOwner, releasedAt: releasedAt))
        #expect(
            try await secondStore.runtimeOwner()
                == DatabaseRuntimeOwnerRecord(
                    token: firstOwner,
                    claimedAt: firstClaimedAt,
                    releasedAt: releasedAt))
        #expect(
            try await secondStore.reserveOperation(staleOperation, for: saved, owner: firstOwner)
                == .runtimeOwnerNotActive)
        let secondClaim = try await secondStore.claimRuntimeOwner(
            claimedAt: Date(timeIntervalSince1970: 703))
        #expect(secondClaim.owner.token != firstOwner)
        #expect(
            try await firstStore.releaseRuntimeOwner(
                firstOwner,
                releasedAt: Date(timeIntervalSince1970: 704)) == false)
    }

    @Test func ownerScopedTransitionsUseMultiStateCASAndRejectLegacyOverwrite() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try SQLiteDatabaseMetadataStore(path: path)
        let secondStore = try SQLiteDatabaseMetadataStore(path: path)
        let otherOwner = DatabaseRuntimeOwnerToken(
            rawValue: UUID(uuidString: "296BB4C1-BAD2-4B5C-88CA-5540359F389D")!)
        let owner = try await firstStore.claimRuntimeOwner(
            claimedAt: Date(timeIntervalSince1970: 100)
        ).owner.token
        let connection = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "5FEE220E-28FD-44B8-973A-B56477B4464A")!,
            name: "CAS",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20))
        try await firstStore.seedConnection(connection)
        let running = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "DD722D6B-38D1-4818-B651-79CCACDB4981")!,
            connection: connection,
            kind: .databaseDisconnect,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: nil)
        #expect(
            try await firstStore.reserveOperation(running, for: connection, owner: owner)
                == .reserved)
        let cancelled = DatabasePersistenceFixtures.operation(
            id: running.id.rawValue,
            connection: connection,
            kind: running.kind,
            state: .cancelled,
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 300))

        #expect(
            try await secondStore.transitionOperation(
                cancelled,
                from: [.running, .cancelling],
                owner: otherOwner) == false)
        try await secondStore.seedOperation(cancelled)
        #expect(try await firstStore.operation(id: running.id) == running)
        #expect(
            try await secondStore.transitionOperation(
                cancelled,
                from: [.running, .cancelling],
                owner: owner))
        #expect(try await firstStore.operation(id: running.id) == cancelled)
        #expect(
            try await firstStore.transitionOperation(
                cancelled,
                from: [.running, .cancelling],
                owner: owner) == false)
        await #expect(
            throws: DatabaseMetadataStoreError.invalidValue(
                name: "operation expected states")
        ) {
            _ = try await firstStore.transitionOperation(
                cancelled,
                from: [],
                owner: owner)
        }
        #expect(
            try await firstStore.releaseRuntimeOwner(
                owner,
                releasedAt: Date(timeIntervalSince1970: 400)))
        #expect(
            try await firstStore.transitionOperation(
                cancelled,
                from: [.cancelled],
                owner: owner) == false)
    }

    @Test func ephemeralReservationsBindOwnerWithoutRequiringSavedConnection() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try SQLiteDatabaseMetadataStore(path: path)
        let secondStore = try SQLiteDatabaseMetadataStore(path: path)
        let owner = try await firstStore.claimRuntimeOwner(
            claimedAt: Date(timeIntervalSince1970: 500)
        ).owner.token
        let unsaved = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "B615D149-D119-4269-8FE1-4DFB58D7FA84")!,
            name: "Unsaved test connection",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200))
        #expect(try await firstStore.connection(id: unsaved.id) == nil)
        let running = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "9534CD10-69AC-4645-B7AC-A663F69DE944")!,
            connection: unsaved,
            kind: .databaseConnectionTest,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 600),
            finishedAt: nil)

        async let firstReservation = firstStore.reserveEphemeralOperation(
            running,
            owner: owner)
        async let secondReservation = secondStore.reserveEphemeralOperation(
            running,
            owner: owner)
        let reservations = try await [firstReservation, secondReservation]
        #expect(reservations.filter { $0 == .reserved }.count == 1)
        #expect(reservations.filter { $0 == .operationIdentifierExists }.count == 1)
        #expect(try await firstStore.operation(id: running.id) == running)

        let legacyOverwrite = DatabaseOperationRecordSummary(
            id: running.id,
            kind: running.kind,
            state: .failed,
            connection: running.connection,
            startedAt: running.startedAt,
            finishedAt: Date(timeIntervalSince1970: 700),
            cancellationSupport: running.cancellationSupport,
            retryClassification: running.retryClassification)
        try await secondStore.seedOperation(legacyOverwrite)
        #expect(try await firstStore.operation(id: running.id) == running)

        #expect(
            try await firstStore.releaseRuntimeOwner(
                owner,
                releasedAt: Date(timeIntervalSince1970: 800)))
        let inactive = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "371C5D43-C7CD-4BA9-B208-52A80E15C0C6")!,
            connection: unsaved,
            kind: .databaseConnectionTest,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 801),
            finishedAt: nil)
        #expect(
            try await firstStore.reserveEphemeralOperation(inactive, owner: owner)
                == .runtimeOwnerNotActive)
        #expect(try await firstStore.operation(id: inactive.id) == nil)
    }

    @Test func claimingNewOwnerAtomicallyRecoversInterruptedOperations() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try SQLiteDatabaseMetadataStore(path: path)
        let secondStore = try SQLiteDatabaseMetadataStore(path: path)
        let firstOwner = try await firstStore.claimRuntimeOwner(
            claimedAt: Date(timeIntervalSince1970: 500)
        ).owner.token
        let connection = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "BF7FA973-352C-4B3A-9DF0-A28EA17FA04E")!,
            name: "Sensitive marker",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20))
        try await firstStore.seedConnection(connection)
        let running = DatabaseOperationRecordSummary(
            id: DatabaseOperationID(
                rawValue: UUID(uuidString: "3DD5145F-3EE8-4E0E-B291-5E4C3471442C")!),
            kind: .databaseConnectionTest,
            state: .running,
            connection: connection.identity,
            target: DatabaseTargetIdentifier(connectionID: connection.id),
            startedAt: Date(timeIntervalSince1970: 600),
            deadline: Date(timeIntervalSince1970: 900),
            progress: .determinate(completed: 4, total: 10, unit: .steps, message: "public"),
            cancellationSupport: .serverSide,
            retryClassification: .requiresReconnect,
            pageCount: 3,
            recordCount: 40,
            byteCount: 500,
            warnings: [
                DatabaseWarning(
                    code: "public.warning",
                    message: "public warning",
                    severity: .caution)
            ],
            partialFailures: [
                DatabasePartialFailure(
                    itemIndex: 2,
                    error: DatabaseErrorEnvelope(
                        category: .server,
                        message: "public partial failure"))
            ])
        let queued = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "25160043-5D62-4C94-8675-BE39D24E13EA")!,
            connection: connection,
            kind: "queued",
            state: .queued,
            startedAt: Date(timeIntervalSince1970: 601),
            finishedAt: nil)
        let cancelling = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "3386A46C-2707-458C-9B09-98308081CC13")!,
            connection: connection,
            kind: "cancelling",
            state: .cancelling,
            startedAt: Date(timeIntervalSince1970: 602),
            finishedAt: nil)
        let legacyRunning = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "746B2A3C-BE88-4A66-940B-1BCE2D06F928")!,
            connection: connection,
            kind: "legacy",
            state: .running,
            startedAt: Date(timeIntervalSince1970: 603),
            finishedAt: nil)
        let succeeded = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "2D039D21-85F9-48E1-B466-C9B35E243A3F")!,
            connection: connection,
            kind: "succeeded",
            state: .succeeded,
            startedAt: Date(timeIntervalSince1970: 604),
            finishedAt: Date(timeIntervalSince1970: 605))
        for operation in [running, queued, cancelling] {
            #expect(
                try await firstStore.reserveOperation(
                    operation,
                    for: connection,
                    owner: firstOwner) == .reserved)
        }
        #expect(try await firstStore.seedOperationIfAbsent(legacyRunning))
        try await firstStore.seedOperation(succeeded)

        let recoveredAt = Date(timeIntervalSince1970: 100)
        let claim = try await secondStore.claimRuntimeOwner(
            claimedAt: recoveredAt)
        let secondOwner = claim.owner.token
        #expect(claim.recoveredOperationCount == 4)
        #expect(
            claim.owner
                == DatabaseRuntimeOwnerRecord(
                    token: secondOwner,
                    claimedAt: recoveredAt))
        #expect(try await firstStore.runtimeOwner() == claim.owner)

        let recoveredRunning = try #require(try await firstStore.operation(id: running.id))
        #expect(recoveredRunning.state == .failed)
        #expect(recoveredRunning.connection == running.connection)
        #expect(recoveredRunning.target == running.target)
        #expect(recoveredRunning.startedAt == running.startedAt)
        #expect(recoveredRunning.finishedAt == running.startedAt)
        #expect(recoveredRunning.deadline == running.deadline)
        #expect(recoveredRunning.progress == running.progress)
        #expect(recoveredRunning.cancellationSupport == running.cancellationSupport)
        #expect(recoveredRunning.retryClassification == .userDecision)
        #expect(recoveredRunning.pageCount == running.pageCount)
        #expect(recoveredRunning.recordCount == running.recordCount)
        #expect(recoveredRunning.byteCount == running.byteCount)
        #expect(recoveredRunning.warnings == running.warnings)
        #expect(recoveredRunning.partialFailures == running.partialFailures)
        #expect(recoveredRunning.error?.category == .internalFailure)
        #expect(recoveredRunning.error?.productCode == "database.runtime.interrupted")
        #expect(
            recoveredRunning.error?.message
                == "The database runtime stopped before the operation completed.")
        #expect(recoveredRunning.error?.target == nil)
        #expect(recoveredRunning.error?.details.isEmpty == true)
        #expect(recoveredRunning.error?.retry.action == .userDecision)
        #expect(recoveredRunning.error?.retry.afterMilliseconds == nil)
        #expect(
            recoveredRunning.error?.retry.message
                == "Review the operation state before deciding whether to retry.")
        #expect(recoveredRunning.error?.message.contains(connection.displayName) == false)
        for operation in [queued, cancelling, legacyRunning] {
            let recovered = try #require(try await secondStore.operation(id: operation.id))
            #expect(recovered.state == .failed)
            #expect(recovered.finishedAt == operation.startedAt)
        }
        #expect(try await secondStore.operation(id: succeeded.id) == succeeded)
        let nextClaim = try await firstStore.claimRuntimeOwner(
            claimedAt: Date(timeIntervalSince1970: 1_000))
        #expect(nextClaim.owner.token != secondOwner)
        #expect(nextClaim.recoveredOperationCount == 0)
    }

    @Test func recoversInterruptedOperationsAcrossBoundedBatches() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDatabaseMetadataStore(path: path)
        let connection = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "C93AD301-8DB5-4EF7-9683-E53F81CE5FE1")!,
            name: "Recovery batches",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20))
        let operationCount = 101
        for index in 0..<operationCount {
            try await store.seedOperation(
                DatabasePersistenceFixtures.operation(
                    id: UUID(),
                    connection: connection,
                    kind: DatabaseOperationKind(rawValue: "batch-\(index)"),
                    state: .running,
                    startedAt: Date(timeIntervalSince1970: Double(index)),
                    finishedAt: nil))
        }

        let claim = try await store.claimRuntimeOwner(
            claimedAt: Date(timeIntervalSince1970: 500))
        #expect(claim.recoveredOperationCount == operationCount)
        let failed = try await store.operations(
            matching: DatabaseOperationHistorySearch(states: [.failed], limit: 200))
        #expect(failed.count == operationCount)
        #expect(failed.allSatisfy { $0.error?.productCode == "database.runtime.interrupted" })
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
            try await store.seedSavedQuery(query)
        }
    }

    @Test func rejectsPayloadIdentifiersAndColumnsThatDoNotMatchTheirRows() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDatabaseMetadataStore(path: path)
        let owner = try await store.claimRuntimeOwner(
            claimedAt: Date(timeIntervalSince1970: 1)
        ).owner.token
        let firstConnection = try DatabasePersistenceFixtures.connection(name: "First")
        let secondConnection = try DatabasePersistenceFixtures.connection(name: "Second")
        try await store.seedConnection(firstConnection)
        try await store.seedConnection(secondConnection)
        let firstConnectionID = firstConnection.id.rawValue.uuidString
        let secondConnectionBlob = try databaseMetadataSQLiteBlob(secondConnection)
        try await store.executeCorruptionSQLForTesting(
            "UPDATE database_connections SET definition = X'\(secondConnectionBlob)' WHERE id = '\(firstConnectionID)'"
        )

        await #expect(throws: DatabaseMetadataStoreError.self) {
            _ = try await store.connection(id: firstConnection.id)
        }
        let editedConnection = try DatabasePersistenceFixtures.connection(
            id: firstConnection.id.rawValue,
            name: "Edited")
        #expect(
            try await store.saveConnection(
                editedConnection,
                replacing: firstConnection,
                owner: owner) == .resourceChanged)
        #expect(try await store.connection(id: secondConnection.id) == secondConnection)

        try await store.seedConnection(firstConnection)
        let firstQuery = DatabasePersistenceFixtures.savedQuery(
            connectionID: firstConnection.id,
            name: "First query")
        let secondQuery = DatabasePersistenceFixtures.savedQuery(
            connectionID: secondConnection.id,
            name: "Second query",
            text: "SELECT 2")
        try await store.seedSavedQuery(firstQuery)
        try await store.seedSavedQuery(secondQuery)
        let firstQueryID = firstQuery.id.rawValue.uuidString
        let secondQueryBlob = try databaseMetadataSQLiteBlob(secondQuery)
        try await store.executeCorruptionSQLForTesting(
            "UPDATE database_saved_queries SET query = X'\(secondQueryBlob)' WHERE id = '\(firstQueryID)'"
        )

        await #expect(throws: DatabaseMetadataStoreError.self) {
            _ = try await store.savedQuery(id: firstQuery.id)
        }
        let editedQuery = DatabasePersistenceFixtures.savedQuery(
            id: firstQuery.id.rawValue,
            connectionID: firstConnection.id,
            name: "Edited query",
            text: "SELECT 3")
        #expect(
            try await store.saveQuery(
                editedQuery,
                replacing: firstQuery,
                validatedAgainst: firstConnection,
                owner: owner) == .resourceChanged)
        #expect(try await store.savedQuery(id: secondQuery.id) == secondQuery)

        try await store.seedSavedQuery(firstQuery)
        try await store.executeCorruptionSQLForTesting(
            "UPDATE database_saved_queries SET connection_id = '\(secondConnection.id.rawValue.uuidString)' WHERE id = '\(firstQueryID)'"
        )
        await #expect(throws: DatabaseMetadataStoreError.self) {
            _ = try await store.savedQueries(matching: DatabaseSavedQuerySearch(limit: 10))
        }

        let firstOperation = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "1DF061F1-E797-4C72-BA47-BF8A47DF2504")!,
            connection: firstConnection,
            kind: "browse",
            state: .succeeded,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200))
        let secondOperation = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "36822B73-2C32-4D85-B80E-5BD94D36FF3E")!,
            connection: secondConnection,
            kind: "export",
            state: .failed,
            startedAt: Date(timeIntervalSince1970: 300),
            finishedAt: Date(timeIntervalSince1970: 400))
        try await store.seedOperation(firstOperation)
        let secondOperationBlob = try databaseMetadataSQLiteBlob(secondOperation)
        try await store.executeCorruptionSQLForTesting(
            "UPDATE database_operation_history SET summary = X'\(secondOperationBlob)' WHERE id = '\(firstOperation.id.rawValue.uuidString)'"
        )
        await #expect(throws: DatabaseMetadataStoreError.self) {
            _ = try await store.operation(id: firstOperation.id)
        }
        await #expect(throws: DatabaseMetadataStoreError.self) {
            _ = try await store.operations(matching: DatabaseOperationHistorySearch(limit: 10))
        }

        let scalarCorruptions = [
            "connection_id = '\(secondConnection.id.rawValue.uuidString)'",
            "kind = 'export'",
            "state = 'failed'",
            "started_at = 101",
            "finished_at = 201",
        ]
        for corruption in scalarCorruptions {
            try await store.seedOperation(firstOperation)
            try await store.executeCorruptionSQLForTesting(
                "UPDATE database_operation_history SET \(corruption) WHERE id = '\(firstOperation.id.rawValue.uuidString)'"
            )
            await #expect(throws: DatabaseMetadataStoreError.self) {
                _ = try await store.operation(id: firstOperation.id)
            }
            await #expect(throws: DatabaseMetadataStoreError.self) {
                _ = try await store.operations(matching: DatabaseOperationHistorySearch(limit: 10))
            }
        }
    }
}
