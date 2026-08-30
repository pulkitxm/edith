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

        async let first = firstStore.createOperationIfAbsent(operation)
        async let second = secondStore.createOperationIfAbsent(operation)
        let reservations = try await [first, second]

        #expect(reservations.filter { $0 }.count == 1)
        #expect(try await firstStore.operation(id: operation.id) == operation)
        #expect(try await secondStore.createOperationIfAbsent(operation) == false)
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
        try await store.saveConnection(saved)
        let first = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "A2D7474C-F123-4F9B-9798-F445F4C02D3C")!,
            connection: saved,
            kind: .databaseConnect,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 300),
            finishedAt: nil)

        #expect(try await store.reserveOperation(first, for: saved) == .reserved)
        #expect(
            try await store.reserveOperation(first, for: saved)
                == .operationIdentifierExists)

        let second = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "E4EB987F-E457-49B3-A8D4-13E685BF7414")!,
            connection: stale,
            kind: .databaseConnect,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 301),
            finishedAt: nil)
        #expect(
            try await store.reserveOperation(second, for: stale)
                == .connectionChangedOrMissing)
        #expect(try await store.deleteConnection(id: saved.id))
        #expect(
            try await store.reserveOperation(second, for: saved)
                == .connectionChangedOrMissing)
    }

    @Test func persistsRuntimeOwnerLifecycleAndOwnedReservationsAcrossStores() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try SQLiteDatabaseMetadataStore(path: path)
        let secondStore = try SQLiteDatabaseMetadataStore(path: path)
        let firstOwner = DatabaseRuntimeOwnerToken(
            rawValue: UUID(uuidString: "A21A346D-E5FA-47F6-B5A7-CAFD3A07D793")!)
        let secondOwner = DatabaseRuntimeOwnerToken(
            rawValue: UUID(uuidString: "3AA531FB-8C04-4EDF-9266-32BA4A5236D7")!)
        let firstClaimedAt = Date(timeIntervalSince1970: 500)

        #expect(try await firstStore.runtimeOwner() == nil)
        await #expect(
            throws: DatabaseMetadataStoreError.invalidValue(
                name: "runtime owner claimed at")
        ) {
            _ = try await firstStore.claimRuntimeOwner(
                firstOwner,
                claimedAt: Date(timeIntervalSince1970: .infinity))
        }
        #expect(try await firstStore.runtimeOwner() == nil)
        let firstClaim = try await firstStore.claimRuntimeOwner(
            firstOwner,
            claimedAt: firstClaimedAt)
        #expect(
            firstClaim
                == DatabaseRuntimeOwnerClaimResult(
                    owner: DatabaseRuntimeOwnerRecord(
                        token: firstOwner,
                        claimedAt: firstClaimedAt),
                    recoveredOperationCount: 0))
        let repeatedClaim = try await secondStore.claimRuntimeOwner(
            firstOwner,
            claimedAt: Date(timeIntervalSince1970: 900))
        #expect(repeatedClaim == firstClaim)

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
        try await firstStore.saveConnection(saved)
        let operation = DatabasePersistenceFixtures.operation(
            id: UUID(uuidString: "FCEAA502-85AB-4919-955B-EE2776DBCC0D")!,
            connection: saved,
            kind: .databaseConnect,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 600),
            finishedAt: nil)

        #expect(
            try await firstStore.reserveOperation(operation, for: saved, owner: secondOwner)
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
                secondOwner,
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
    }

    @Test func ownerScopedTransitionsUseMultiStateCASAndRejectLegacyOverwrite() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try SQLiteDatabaseMetadataStore(path: path)
        let secondStore = try SQLiteDatabaseMetadataStore(path: path)
        let owner = DatabaseRuntimeOwnerToken(
            rawValue: UUID(uuidString: "C622299B-79C3-4709-9653-E2FEC8F4E5A6")!)
        let otherOwner = DatabaseRuntimeOwnerToken(
            rawValue: UUID(uuidString: "296BB4C1-BAD2-4B5C-88CA-5540359F389D")!)
        _ = try await firstStore.claimRuntimeOwner(
            owner,
            claimedAt: Date(timeIntervalSince1970: 100))
        let connection = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "5FEE220E-28FD-44B8-973A-B56477B4464A")!,
            name: "CAS",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20))
        try await firstStore.saveConnection(connection)
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
        try await secondStore.recordOperation(cancelled)
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

    @Test func claimingNewOwnerAtomicallyRecoversInterruptedOperations() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try SQLiteDatabaseMetadataStore(path: path)
        let secondStore = try SQLiteDatabaseMetadataStore(path: path)
        let firstOwner = DatabaseRuntimeOwnerToken(
            rawValue: UUID(uuidString: "1D87B97C-8737-4F81-BB46-9F01420C5350")!)
        let secondOwner = DatabaseRuntimeOwnerToken(
            rawValue: UUID(uuidString: "41C7D63F-3351-4BC6-B042-E12FDF1F9EEE")!)
        _ = try await firstStore.claimRuntimeOwner(
            firstOwner,
            claimedAt: Date(timeIntervalSince1970: 500))
        let connection = try DatabasePersistenceFixtures.connection(
            id: UUID(uuidString: "BF7FA973-352C-4B3A-9DF0-A28EA17FA04E")!,
            name: "Sensitive marker",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20))
        try await firstStore.saveConnection(connection)
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
        #expect(try await firstStore.createOperationIfAbsent(legacyRunning))
        try await firstStore.recordOperation(succeeded)

        let recoveredAt = Date(timeIntervalSince1970: 100)
        let claim = try await secondStore.claimRuntimeOwner(
            secondOwner,
            claimedAt: recoveredAt)
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
        let repeatedClaim = try await firstStore.claimRuntimeOwner(
            secondOwner,
            claimedAt: Date(timeIntervalSince1970: 1_000))
        #expect(repeatedClaim.owner == claim.owner)
        #expect(repeatedClaim.recoveredOperationCount == 0)
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
            try await store.recordOperation(
                DatabasePersistenceFixtures.operation(
                    id: UUID(),
                    connection: connection,
                    kind: DatabaseOperationKind(rawValue: "batch-\(index)"),
                    state: .running,
                    startedAt: Date(timeIntervalSince1970: Double(index)),
                    finishedAt: nil))
        }

        let claim = try await store.claimRuntimeOwner(
            DatabaseRuntimeOwnerToken(
                rawValue: UUID(uuidString: "AFB119F6-FFED-4D71-8F38-95A12D123282")!),
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
            try await store.saveQuery(query)
        }
    }
}
