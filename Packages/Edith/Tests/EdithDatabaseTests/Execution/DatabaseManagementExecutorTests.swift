import Foundation
import Testing

@testable import EdithDatabase

private final class DatabaseManagementClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func read() -> Date {
        lock.withLock { value }
    }

    func set(_ value: Date) {
        lock.withLock { self.value = value }
    }
}

private final class DatabaseManagementUUIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.withLock { values.isEmpty ? UUID() : values.removeFirst() }
    }
}

private struct DatabaseManagementFixture {
    let directory: URL
    let store: SQLiteDatabaseMetadataStore
    let secretStore: InMemoryDatabaseSecretStore
    let owner: DatabaseRuntimeOwnerToken
    let executor: DatabaseExecutor
}

private enum DatabaseManagementConnectionMutation: CaseIterable, Equatable {
    case edit
    case rename

    var resultName: String {
        switch self {
        case .edit:
            "Orders edited"
        case .rename:
            "Orders renamed"
        }
    }
}

private enum DatabaseManagementFixtures {
    static let initialDate = Date(timeIntervalSince1970: 1_900_000_000)

    static func uuid(_ value: UInt8) -> UUID {
        UUID(
            uuid: (
                0x74, 0x35, 0xB2, 0x8C, 0x61, 0xA9, 0x4D, 0x1B,
                0x90, 0x02, 0x43, 0x08, 0x77, 0x00, 0x00, value
            ))
    }

    static func connection(
        id: UInt8 = 1,
        name: String = "Orders",
        product: DatabaseProduct = .postgresql,
        references: [DatabaseSecretReference] = [],
        authentication: DatabaseAuthentication? = nil,
        tls: DatabaseTLSConfiguration = DatabaseTLSConfiguration(
            mode: .disabled,
            verification: .none),
        tags: [String] = ["core"],
        options: [DatabaseNonSecretOption] = [],
        createdAt: Date = Date(timeIntervalSince1970: 100),
        updatedAt: Date = Date(timeIntervalSince1970: 200)
    ) throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            id: DatabaseConnectionID(rawValue: uuid(id)),
            displayName: name,
            productHint: product,
            location: .network([
                DatabaseNetworkEndpoint(host: "127.0.0.1", port: try DatabasePort(5_432))
            ]),
            username: "edith",
            namespaces: DatabaseNamespaceDefaults(schema: "public", database: "app"),
            deploymentMode: .standalone,
            authentication: authentication
                ?? (references.isEmpty
                    ? DatabaseAuthentication(kind: .none)
                    : DatabaseAuthentication(kind: .password, secretReferences: references)),
            tls: tls,
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
                poolSize: try DatabasePoolSize(4)),
            environment: DatabaseEnvironmentMetadata(
                kind: .development,
                label: "development",
                protection: .standard),
            group: "services",
            tags: tags,
            options: options,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }

    static func query(
        id: UInt8 = 40,
        connectionID: DatabaseConnectionID?,
        name: String = "Recent orders",
        language: DatabaseSavedQueryLanguage = .sql,
        text: String = "SELECT * FROM orders",
        createdAt: Date = Date(timeIntervalSince1970: 100),
        updatedAt: Date = Date(timeIntervalSince1970: 200)
    ) -> DatabaseSavedQuery {
        DatabaseSavedQuery(
            id: DatabaseSavedQueryID(rawValue: uuid(id)),
            connectionID: connectionID,
            name: name,
            language: language,
            text: text,
            tags: ["orders"],
            createdAt: createdAt,
            updatedAt: updatedAt)
    }

    static func operation(_ value: UInt8) -> DatabaseOperationContext {
        DatabaseOperationContext(
            operationID: DatabaseOperationID(rawValue: uuid(value)))
    }

    static func make(
        clock: DatabaseManagementClock,
        uuidSource: DatabaseManagementUUIDSource = DatabaseManagementUUIDSource([]),
        secrets: [DatabaseSecretReference: Data] = [:],
        adapters: [any DatabaseAdapter] = []
    ) async throws -> DatabaseManagementFixture {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        let store = try SQLiteDatabaseMetadataStore(path: path)
        let owner = try await store.claimRuntimeOwner(
            claimedAt: clock.read().addingTimeInterval(-1)
        ).owner.token
        let secretStore = try InMemoryDatabaseSecretStore(initialValues: secrets)
        let executor = try DatabaseExecutor(
            metadataStore: store,
            secretStore: secretStore,
            runtimeOwner: owner,
            adapters: adapters,
            currentDate: { clock.read() },
            makeUUID: { uuidSource.next() })
        return DatabaseManagementFixture(
            directory: directory,
            store: store,
            secretStore: secretStore,
            owner: owner,
            executor: executor)
    }

    static func adapter(
        connection: DatabaseConnectionDefinition,
        gates: DatabaseExecutorTestSessionGates = DatabaseExecutorTestSessionGates()
    ) throws -> (DatabaseExecutorRecordingAdapter, DatabaseExecutorRecordingSession) {
        let identity = DatabaseProductIdentity(
            product: connection.productHint,
            version: DatabaseVersion(string: "1.0.0"),
            topology: DatabaseTopology(kind: .standalone))
        let report = DatabaseCapabilityReport(
            productIdentity: identity,
            capabilities: [
                DatabaseCapabilityStatus(
                    id: .query,
                    requirement: .sharedRequired,
                    availability: .available)
            ],
            discoveredAt: initialDate,
            expiresAt: initialDate.addingTimeInterval(600))
        let page = try DatabaseAdapterPage(
            records: [],
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(state: .complete),
                count: DatabaseCountMetadata(value: 0, accuracy: .exact)))
        let target = DatabaseTargetIdentifier(connectionID: connection.id)
        let plan = DatabaseDestructivePlan(
            request: DatabaseDestructiveRequest(
                target: target,
                payload: .administrative(
                    product: connection.productHint,
                    command: "maintenance",
                    parameters: [],
                    body: nil)),
            action: .maintenance,
            scope: .entireObject,
            impact: DatabaseMutationImpact(
                count: DatabaseCountMetadata(value: 0, accuracy: .exact),
                description: "none"),
            transactionBehavior: .productDependent,
            rollbackAvailability: .unavailable,
            executionMode: .synchronous)
        let session = DatabaseExecutorRecordingSession(
            id: DatabaseAdapterSessionID(rawValue: uuid(230)),
            connection: connection,
            productIdentity: identity,
            capabilities: report,
            page: page,
            queryPage: page,
            mutationPlan: plan,
            mutationResult: try DatabaseAdapterMutationResult(
                disposition: .completed,
                affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .exact)),
            gates: gates)
        return (
            DatabaseExecutorRecordingAdapter(
                id: DatabaseAdapterID(rawValue: "management-recording"),
                products: [connection.productHint],
                session: session),
            session
        )
    }
}

@Suite struct DatabaseManagementExecutorTests {
    @Test func connectionLifecyclePreservesSecretsAndTimestamps() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let duplicateID = DatabaseManagementFixtures.uuid(2)
        let password = DatabaseSecretReference(
            identifier: DatabaseManagementFixtures.uuid(200),
            purpose: .password)
        let fixture = try await DatabaseManagementFixtures.make(
            clock: clock,
            uuidSource: DatabaseManagementUUIDSource([duplicateID]),
            secrets: [password: Data("private-value".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = try DatabaseManagementFixtures.connection(references: [password])

        let saved = await fixture.executor.saveConnection(
            DatabaseConnectionSaveRequest(connection: input))
        let savedConnection = try #require(saved.payload?.connection)
        #expect(savedConnection.createdAt == clock.read())
        #expect(savedConnection.updatedAt == clock.read())
        #expect(
            await fixture.executor.connection(
                DatabaseConnectionGetRequest(connectionID: input.id)
            ).payload?.connection
                == savedConnection)

        clock.set(clock.read().addingTimeInterval(10))
        let editInput = try DatabaseManagementFixtures.connection(
            name: "Orders edited",
            references: [password],
            tags: ["edited"])
        let edited = try #require(
            await fixture.executor.editConnection(
                DatabaseConnectionEditRequest(
                    connectionID: input.id,
                    connection: editInput)
            ).payload?.connection)
        #expect(edited.createdAt == savedConnection.createdAt)
        #expect(edited.updatedAt == clock.read())

        clock.set(clock.read().addingTimeInterval(10))
        let renamed = try #require(
            await fixture.executor.renameConnection(
                DatabaseConnectionRenameRequest(
                    connectionID: input.id,
                    displayName: "Orders primary")
            ).payload?.connection)
        #expect(renamed.displayName == "Orders primary")
        #expect(renamed.createdAt == savedConnection.createdAt)

        clock.set(clock.read().addingTimeInterval(10))
        let duplicated = try #require(
            await fixture.executor.duplicateConnection(
                DatabaseConnectionDuplicateRequest(
                    connectionID: input.id,
                    displayName: "Orders copy")
            ).payload)
        #expect(duplicated.connection.id.rawValue == duplicateID)
        #expect(duplicated.connection.createdAt == clock.read())
        #expect(duplicated.sharesCredentials)
        #expect(duplicated.sharedCredentialReferences == [password])
        #expect(await fixture.secretStore.contains(password))
        let listed = try #require(
            await fixture.executor.connections(DatabaseConnectionListRequest()).payload)
        #expect(Set(listed.connections.map(\.id)) == [input.id, duplicated.connection.id])

        let deleted = try #require(
            await fixture.executor.deleteConnection(
                DatabaseConnectionDeleteRequest(connectionID: input.id)
            ).payload)
        let repeated = try #require(
            await fixture.executor.deleteConnection(
                DatabaseConnectionDeleteRequest(connectionID: input.id)
            ).payload)
        #expect(deleted.deleted)
        #expect(!repeated.deleted)
        #expect(await fixture.secretStore.contains(password))
        #expect(
            await fixture.executor.renameConnection(
                DatabaseConnectionRenameRequest(
                    connectionID: input.id,
                    displayName: "missing")
            ).error?.category == .invalidRequest)
    }

    @Test func savedQueryLifecyclePreservesCreationTime() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let duplicateID = DatabaseManagementFixtures.uuid(41)
        let fixture = try await DatabaseManagementFixtures.make(
            clock: clock,
            uuidSource: DatabaseManagementUUIDSource([duplicateID]))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connection = try DatabaseManagementFixtures.connection()
        try await fixture.store.seedConnection(connection)
        let input = DatabaseManagementFixtures.query(connectionID: connection.id)

        let first = try #require(
            await fixture.executor.saveSavedQuery(
                DatabaseSavedQuerySaveRequest(query: input)
            ).payload)
        #expect(first.created)
        clock.set(clock.read().addingTimeInterval(10))
        let changed = DatabaseManagementFixtures.query(
            connectionID: connection.id,
            text: "SELECT id FROM orders")
        let updated = try #require(
            await fixture.executor.saveSavedQuery(
                DatabaseSavedQuerySaveRequest(query: changed)
            ).payload)
        #expect(!updated.created)
        #expect(updated.query.createdAt == first.query.createdAt)
        #expect(updated.query.updatedAt == clock.read())

        clock.set(clock.read().addingTimeInterval(10))
        let renamed = try #require(
            await fixture.executor.renameSavedQuery(
                DatabaseSavedQueryRenameRequest(
                    queryID: input.id,
                    name: "Orders by ID")
            ).payload?.query)
        #expect(renamed.name == "Orders by ID")
        clock.set(clock.read().addingTimeInterval(10))
        let duplicated = try #require(
            await fixture.executor.duplicateSavedQuery(
                DatabaseSavedQueryDuplicateRequest(
                    queryID: input.id,
                    name: "Orders copy")
            ).payload?.query)
        #expect(duplicated.id.rawValue == duplicateID)
        #expect(duplicated.createdAt == clock.read())
        #expect(
            await fixture.executor.savedQuery(
                DatabaseSavedQueryGetRequest(queryID: duplicated.id)
            ).payload?.query == duplicated)
        #expect(
            await fixture.executor.savedQueries(
                DatabaseSavedQueryListRequest()
            ).payload?.queries.count == 2)

        #expect(
            await fixture.executor.deleteSavedQuery(
                DatabaseSavedQueryDeleteRequest(queryID: input.id)
            ).payload?.deleted == true)
        #expect(
            await fixture.executor.deleteSavedQuery(
                DatabaseSavedQueryDeleteRequest(queryID: input.id)
            ).payload?.deleted == false)
    }

    @Test func savedQueryRenameReportsConcurrentChangeAsConflict() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let fixture = try await DatabaseManagementFixtures.make(clock: clock)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connection = try DatabaseManagementFixtures.connection(id: 23)
        let query = DatabaseManagementFixtures.query(id: 60, connectionID: connection.id)
        try await fixture.store.seedConnection(connection)
        try await fixture.store.seedSavedQuery(query)
        let writeGate = DatabaseExecutorTestGate(open: false)
        let proxy = DatabaseExecutorMetadataStoreProxy(
            base: fixture.store,
            savedQueryWriteGate: writeGate)
        let executor = try DatabaseExecutor(
            metadataStore: proxy,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [],
            currentDate: { clock.read() })
        let renameTask = Task {
            await executor.renameSavedQuery(
                DatabaseSavedQueryRenameRequest(queryID: query.id, name: "Renamed"))
        }
        await writeGate.waitForEntries()
        let concurrent = DatabaseManagementFixtures.query(
            id: 60,
            connectionID: connection.id,
            name: "Concurrent",
            text: "SELECT id FROM orders",
            createdAt: query.createdAt,
            updatedAt: query.updatedAt.addingTimeInterval(1))
        try await fixture.store.seedSavedQuery(concurrent)
        await writeGate.releaseAll()

        let result = await renameTask.value
        #expect(result.error?.category == .conflict)
        #expect(
            result.error?.message
                == "The saved database query changed before the operation started.")
        #expect(try await fixture.store.savedQuery(id: query.id) == concurrent)
    }

    @Test func savedQueryRenameReportsConcurrentDeletionAsMissing() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let fixture = try await DatabaseManagementFixtures.make(clock: clock)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connection = try DatabaseManagementFixtures.connection(id: 24)
        let query = DatabaseManagementFixtures.query(id: 61, connectionID: connection.id)
        try await fixture.store.seedConnection(connection)
        try await fixture.store.seedSavedQuery(query)
        let writeGate = DatabaseExecutorTestGate(open: false)
        let proxy = DatabaseExecutorMetadataStoreProxy(
            base: fixture.store,
            savedQueryWriteGate: writeGate)
        let executor = try DatabaseExecutor(
            metadataStore: proxy,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [],
            currentDate: { clock.read() })
        let renameTask = Task {
            await executor.renameSavedQuery(
                DatabaseSavedQueryRenameRequest(queryID: query.id, name: "Renamed"))
        }
        await writeGate.waitForEntries()
        #expect(try await fixture.store.removeSeededSavedQuery(id: query.id))
        await writeGate.releaseAll()

        let result = await renameTask.value
        #expect(result.error?.category == .invalidRequest)
        #expect(result.error?.message == "The saved database query was not found.")
        #expect(try await fixture.store.savedQuery(id: query.id) == nil)
    }

    @Test func validationRejectsMalformedManagementInputs() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let fixture = try await DatabaseManagementFixtures.make(clock: clock)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let zero = DatabaseConnectionID(
            rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        let reference = DatabaseSecretReference(
            identifier: DatabaseManagementFixtures.uuid(201),
            purpose: .password)
        let token = DatabaseSecretReference(
            identifier: DatabaseManagementFixtures.uuid(202),
            purpose: .token)
        let privateKey = DatabaseSecretReference(
            identifier: DatabaseManagementFixtures.uuid(203),
            purpose: .clientPrivateKey)
        let certificate = DatabaseResourceReference(
            identifier: DatabaseManagementFixtures.uuid(204),
            kind: .clientCertificate)
        let duplicateReferences = try DatabaseManagementFixtures.connection(
            references: [reference, reference])
        let duplicateTags = try DatabaseManagementFixtures.connection(tags: ["Core", "core"])
        let secretOption = try DatabaseManagementFixtures.connection(
            options: [DatabaseNonSecretOption(name: "api_token", value: .string("value"))])
        let badTimestamp = try DatabaseManagementFixtures.connection(
            createdAt: Date(timeIntervalSince1970: 300),
            updatedAt: Date(timeIntervalSince1970: 200))
        let mismatchedAuthentication = try DatabaseManagementFixtures.connection(
            id: 2,
            references: [token])
        let disabledTLSMetadata = try DatabaseManagementFixtures.connection(
            id: 3,
            tls: DatabaseTLSConfiguration(
                mode: .disabled,
                verification: .none,
                serverName: "database.example"))
        let validX509 = try DatabaseManagementFixtures.connection(
            id: 4,
            authentication: DatabaseAuthentication(kind: .x509),
            tls: DatabaseTLSConfiguration(
                mode: .required,
                verification: .full,
                clientCertificate: certificate,
                clientPrivateKey: privateKey))
        let invalidResults = [
            await fixture.executor.connections(
                DatabaseConnectionListRequest(version: 2)),
            await fixture.executor.connections(
                DatabaseConnectionListRequest(
                    search: DatabaseConnectionSearch(limit: 501))),
        ]
        #expect(invalidResults.allSatisfy { $0.status == .failed })
        #expect(
            await fixture.executor.connections(
                DatabaseConnectionListRequest(
                    search: DatabaseConnectionSearch(limit: 0))
            ).error?.category == .invalidRequest)
        #expect(
            await fixture.executor.connections(
                DatabaseConnectionListRequest(
                    search: DatabaseConnectionSearch(offset: -1))
            ).error?.category == .invalidRequest)
        #expect(
            await fixture.executor.connection(
                DatabaseConnectionGetRequest(connectionID: zero)
            ).status == .failed)
        for connection in [
            duplicateReferences, duplicateTags, secretOption, badTimestamp,
            mismatchedAuthentication, disabledTLSMetadata,
        ] {
            #expect(
                await fixture.executor.saveConnection(
                    DatabaseConnectionSaveRequest(connection: connection)
                ).status == .failed)
        }
        #expect(
            await fixture.executor.saveConnection(
                DatabaseConnectionSaveRequest(connection: validX509)
            ).status == .succeeded)

        let connection = try DatabaseManagementFixtures.connection()
        try await fixture.store.seedConnection(connection)
        let mismatch = DatabaseManagementFixtures.query(
            connectionID: connection.id,
            language: .redisCommand,
            text: "GET orders")
        let oversized = DatabaseManagementFixtures.query(
            id: 41,
            connectionID: connection.id,
            text: String(repeating: "x", count: 1_048_577))
        #expect(
            await fixture.executor.saveSavedQuery(
                DatabaseSavedQuerySaveRequest(query: mismatch)
            ).error?.category == .invalidRequest)
        #expect(
            await fixture.executor.saveSavedQuery(
                DatabaseSavedQuerySaveRequest(query: oversized)
            ).error?.category == .resourceLimit)
    }

    @Test func malformedStoredValuesMapToInternalFailures() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let fixture = try await DatabaseManagementFixtures.make(clock: clock)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let token = DatabaseSecretReference(
            identifier: DatabaseManagementFixtures.uuid(205),
            purpose: .token)
        let connection = try DatabaseManagementFixtures.connection(
            id: 5,
            references: [token])
        try await fixture.store.seedConnection(connection)

        #expect(
            await fixture.executor.connection(
                DatabaseConnectionGetRequest(connectionID: connection.id)
            ).error?.category == .internalFailure)
        #expect(
            await fixture.executor.connections(
                DatabaseConnectionListRequest()
            ).error?.category == .internalFailure)
        let rejectedQuery = DatabaseManagementFixtures.query(
            id: 43,
            connectionID: connection.id)
        #expect(
            await fixture.executor.saveSavedQuery(
                DatabaseSavedQuerySaveRequest(query: rejectedQuery)
            ).error?.category == .internalFailure)
        #expect(try await fixture.store.savedQuery(id: rejectedQuery.id) == nil)

        let validConnection = try DatabaseManagementFixtures.connection(id: 6)
        try await fixture.store.seedConnection(validConnection)
        let query = DatabaseManagementFixtures.query(
            id: 42,
            connectionID: validConnection.id,
            language: .redisCommand,
            text: "GET orders")
        try await fixture.store.seedSavedQuery(query)
        #expect(
            await fixture.executor.savedQuery(
                DatabaseSavedQueryGetRequest(queryID: query.id)
            ).error?.category == .internalFailure)
        #expect(
            await fixture.executor.savedQueries(
                DatabaseSavedQueryListRequest()
            ).error?.category == .internalFailure)
    }

    @Test func ownerLossAndConcurrentCreateAreDeterministic() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let fixture = try await DatabaseManagementFixtures.make(clock: clock)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connection = try DatabaseManagementFixtures.connection()
        let secondExecutor = try DatabaseExecutor(
            metadataStore: fixture.store,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [],
            currentDate: { clock.read() })

        async let first = fixture.executor.saveConnection(
            DatabaseConnectionSaveRequest(connection: connection))
        async let second = secondExecutor.saveConnection(
            DatabaseConnectionSaveRequest(connection: connection))
        let statuses = await [first.status, second.status]
        #expect(statuses.filter { $0 == .succeeded }.count == 1)
        #expect(statuses.filter { $0 == .failed }.count == 1)

        let duplicateID = DatabaseManagementFixtures.uuid(9)
        let duplicateUUIDs = Array(repeating: duplicateID, count: 16)
        let firstDuplicateSource = DatabaseManagementUUIDSource(duplicateUUIDs)
        let firstDuplicateExecutor = try DatabaseExecutor(
            metadataStore: fixture.store,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [],
            currentDate: { clock.read() },
            makeUUID: { firstDuplicateSource.next() })
        let secondDuplicateSource = DatabaseManagementUUIDSource(duplicateUUIDs)
        let secondDuplicateExecutor = try DatabaseExecutor(
            metadataStore: fixture.store,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [],
            currentDate: { clock.read() },
            makeUUID: { secondDuplicateSource.next() })
        async let firstDuplicate = firstDuplicateExecutor.duplicateConnection(
            DatabaseConnectionDuplicateRequest(
                connectionID: connection.id,
                displayName: "First copy"))
        async let secondDuplicate = secondDuplicateExecutor.duplicateConnection(
            DatabaseConnectionDuplicateRequest(
                connectionID: connection.id,
                displayName: "Second copy"))
        let duplicateStatuses = await [firstDuplicate.status, secondDuplicate.status]
        #expect(duplicateStatuses.filter { $0 == .succeeded }.count == 1)
        #expect(duplicateStatuses.filter { $0 == .failed }.count == 1)

        #expect(
            try await fixture.store.releaseRuntimeOwner(
                fixture.owner,
                releasedAt: clock.read()))
        #expect(
            await fixture.executor.connections(
                DatabaseConnectionListRequest()
            ).error?.category == .conflict)
        #expect(
            await fixture.executor.deleteConnection(
                DatabaseConnectionDeleteRequest(connectionID: connection.id)
            ).error?.category
                == .conflict)
        #expect(try await fixture.store.connection(id: connection.id) != nil)
    }

    @Test func ownershipLossDuringCreatePreventsTheWrite() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let fixture = try await DatabaseManagementFixtures.make(clock: clock)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = DatabaseExecutorTestGate(open: false)
        let proxy = DatabaseExecutorMetadataStoreProxy(
            base: fixture.store,
            connectionWriteGate: gate)
        let executor = try DatabaseExecutor(
            metadataStore: proxy,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [],
            currentDate: { clock.read() })
        let connection = try DatabaseManagementFixtures.connection(id: 7)
        let saveTask = Task {
            await executor.saveConnection(
                DatabaseConnectionSaveRequest(connection: connection))
        }
        await gate.waitForEntries()
        #expect(
            try await fixture.store.releaseRuntimeOwner(
                fixture.owner,
                releasedAt: clock.read()))
        _ = try await fixture.store.claimRuntimeOwner(
            claimedAt: clock.read().addingTimeInterval(1))
        await gate.releaseAll()

        #expect(await saveTask.value.error?.category == .conflict)
        #expect(try await fixture.store.connection(id: connection.id) == nil)
    }

    @Test func cancelledQueuedMutationIsRemovedBeforeTheActiveMutationFinishes() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let fixture = try await DatabaseManagementFixtures.make(clock: clock)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writeGate = DatabaseExecutorTestGate(open: false)
        let proxy = DatabaseExecutorMetadataStoreProxy(
            base: fixture.store,
            connectionWriteGate: writeGate)
        let firstExecutor = try DatabaseExecutor(
            metadataStore: proxy,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [],
            currentDate: { clock.read() })
        let firstConnection = try DatabaseManagementFixtures.connection(id: 12)
        let queuedConnection = try DatabaseManagementFixtures.connection(id: 13)
        let activeTask = Task {
            await firstExecutor.saveConnection(
                DatabaseConnectionSaveRequest(connection: firstConnection))
        }
        await writeGate.waitForEntries()
        let queuedTask = Task {
            await fixture.executor.saveConnection(
                DatabaseConnectionSaveRequest(connection: queuedConnection))
        }
        while await fixture.executor.managementMutationWaiterCount() == 0 {
            await Task.yield()
        }

        queuedTask.cancel()
        while await fixture.executor.managementMutationWaiterCount() != 0 {
            await Task.yield()
        }
        let cancelled = await queuedTask.value
        #expect(cancelled.error?.category == .cancelled)
        #expect(try await fixture.store.connection(id: queuedConnection.id) == nil)

        await writeGate.releaseAll()
        #expect(await activeTask.value.status == .succeeded)
        #expect(try await fixture.store.connection(id: firstConnection.id) != nil)
    }

    @Test func productEditRejectsIncompatibleLinkedSavedQueries() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let fixture = try await DatabaseManagementFixtures.make(clock: clock)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connection = try DatabaseManagementFixtures.connection(id: 14)
        let query = DatabaseManagementFixtures.query(
            id: 54,
            connectionID: connection.id)
        try await fixture.store.seedConnection(connection)
        try await fixture.store.seedSavedQuery(query)
        let redis = try DatabaseManagementFixtures.connection(
            id: 14,
            name: "Orders redis",
            product: .redis)

        let result = await fixture.executor.editConnection(
            DatabaseConnectionEditRequest(
                connectionID: connection.id,
                connection: redis))

        #expect(result.error?.category == .invalidRequest)
        #expect(try await fixture.store.connection(id: connection.id)?.productHint == .postgresql)
        #expect(try await fixture.store.savedQuery(id: query.id) == query)
    }

    @Test func savedQueryListsReadEachConnectionOnce() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let fixture = try await DatabaseManagementFixtures.make(clock: clock)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connection = try DatabaseManagementFixtures.connection(id: 8)
        try await fixture.store.seedConnection(connection)
        for id: UInt8 in 50...52 {
            try await fixture.store.seedSavedQuery(
                DatabaseManagementFixtures.query(
                    id: id,
                    connectionID: connection.id,
                    name: "Query \(id)"))
        }
        let proxy = DatabaseExecutorMetadataStoreProxy(base: fixture.store)
        let executor = try DatabaseExecutor(
            metadataStore: proxy,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [],
            currentDate: { clock.read() })

        let result = await executor.savedQueries(DatabaseSavedQueryListRequest())
        #expect(result.payload?.queries.count == 3)
        #expect(await proxy.connectionReadCount() == 1)
    }

    @Test func deleteCancelsThenDisconnectsBeforeMetadataRemoval() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let password = DatabaseSecretReference(
            identifier: DatabaseManagementFixtures.uuid(210),
            purpose: .password)
        let connection = try DatabaseManagementFixtures.connection(references: [password])
        let lifecycleGate = DatabaseExecutorTestGate()
        let disconnectGate = DatabaseExecutorTestGate(open: false)
        let sessionGates = DatabaseExecutorTestSessionGates(
            lifecycleState: lifecycleGate,
            disconnect: disconnectGate)
        let (adapter, session) = try DatabaseManagementFixtures.adapter(
            connection: connection,
            gates: sessionGates)
        let fixture = try await DatabaseManagementFixtures.make(
            clock: clock,
            secrets: [password: Data("password-value".utf8)],
            adapters: [adapter])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.seedConnection(connection)
        let peerConnectionGate = DatabaseExecutorTestGate()
        let peerStore = DatabaseExecutorMetadataStoreProxy(
            base: fixture.store,
            connectionGate: peerConnectionGate)
        let peerExecutor = try DatabaseExecutor(
            metadataStore: peerStore,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [adapter],
            currentDate: { clock.read() })

        let connected = await fixture.executor.connect(
            DatabaseConnectRequest(
                connectionID: connection.id,
                operation: DatabaseManagementFixtures.operation(100)))
        #expect(connected.status == .succeeded)
        #expect(connected.payload?.connection.displayName == connection.displayName)
        #expect(
            await adapter.recordedInvocations().first?.secrets == [
                password: Data("password-value".utf8)
            ])
        #expect(
            await peerExecutor.connect(
                DatabaseConnectRequest(
                    connectionID: connection.id,
                    operation: DatabaseManagementFixtures.operation(103))
            ).status == .succeeded)

        let lifecycleEntries = await lifecycleGate.entryCount()
        await lifecycleGate.block()
        let capabilitiesOperation = DatabaseManagementFixtures.operation(101)
        let capabilitiesTask = Task {
            await peerExecutor.capabilities(
                DatabaseCapabilitiesRequest(
                    connectionID: connection.id,
                    operation: capabilitiesOperation))
        }
        await lifecycleGate.waitForEntries(lifecycleEntries + 1)
        let connectionEntries = await peerConnectionGate.entryCount()
        await peerConnectionGate.block()
        let pendingAdmissionTask = Task {
            await peerExecutor.capabilities(
                DatabaseCapabilitiesRequest(
                    connectionID: connection.id,
                    operation: DatabaseManagementFixtures.operation(102)))
        }
        await peerConnectionGate.waitForEntries(connectionEntries + 1)
        let deleteTask = Task {
            await fixture.executor.deleteConnection(
                DatabaseConnectionDeleteRequest(connectionID: connection.id))
        }
        await disconnectGate.waitForEntries()
        #expect(
            try await fixture.store.operation(id: capabilitiesOperation.operationID)?.state
                == .cancelling)
        #expect(try await fixture.store.connection(id: connection.id) != nil)
        await peerConnectionGate.releaseAll()
        #expect(await pendingAdmissionTask.value.error?.category == .conflict)
        #expect(
            try await fixture.store.releaseRuntimeOwner(
                fixture.owner,
                releasedAt: clock.read()))
        await lifecycleGate.releaseAll()
        await disconnectGate.releaseAll()

        let interruptedDelete = await deleteTask.value
        let capabilitiesResult = await capabilitiesTask.value
        #expect(interruptedDelete.error?.category == .conflict)
        #expect(capabilitiesResult.status == .failed)
        #expect(try await fixture.store.connection(id: connection.id) != nil)
        #expect(await session.snapshot().disconnectCount == 2)
        #expect(await fixture.secretStore.contains(password))

        let replacementOwner = try await fixture.store.claimRuntimeOwner(
            claimedAt: clock.read()
        ).owner.token
        let replacementExecutor = try DatabaseExecutor(
            metadataStore: fixture.store,
            secretStore: fixture.secretStore,
            runtimeOwner: replacementOwner,
            adapters: [adapter],
            currentDate: { clock.read() })
        let deleted = await replacementExecutor.deleteConnection(
            DatabaseConnectionDeleteRequest(connectionID: connection.id))
        #expect(deleted.payload?.deleted == true)
        #expect(deleted.payload?.disconnected == false)
        #expect(try await fixture.store.connection(id: connection.id) == nil)
    }

    @Test func deletionAwaitsServerCancellationBeforeDisconnecting() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let connection = try DatabaseManagementFixtures.connection(id: 15)
        let cancellationGate = DatabaseExecutorTestGate(open: false)
        let disconnectGate = DatabaseExecutorTestGate(open: false)
        let terminalGate = DatabaseExecutorTestGate(open: false)
        let sessionGates = DatabaseExecutorTestSessionGates(
            cancel: cancellationGate,
            disconnect: disconnectGate)
        let (adapter, session) = try DatabaseManagementFixtures.adapter(
            connection: connection,
            gates: sessionGates)
        let fixture = try await DatabaseManagementFixtures.make(
            clock: clock,
            adapters: [adapter])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.seedConnection(connection)
        let proxy = DatabaseExecutorMetadataStoreProxy(
            base: fixture.store,
            terminalTransitionGate: terminalGate)
        let connectExecutor = try DatabaseExecutor(
            metadataStore: proxy,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [adapter],
            currentDate: { clock.read() })
        let deleteExecutor = try DatabaseExecutor(
            metadataStore: fixture.store,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [adapter],
            currentDate: { clock.read() },
            managementDrainTimeoutNanoseconds: 50_000_000)
        let connectTask = Task {
            await connectExecutor.connect(
                DatabaseConnectRequest(
                    connectionID: connection.id,
                    operation: DatabaseManagementFixtures.operation(115)))
        }
        await terminalGate.waitForEntries()
        let deleteTask = Task {
            await deleteExecutor.deleteConnection(
                DatabaseConnectionDeleteRequest(connectionID: connection.id))
        }
        await cancellationGate.waitForEntries()

        #expect(await disconnectGate.entryCount() == 0)
        #expect(try await fixture.store.connection(id: connection.id) != nil)
        #expect(await deleteTask.value.error?.category == .timeout)
        let blockedRetry = await deleteExecutor.deleteConnection(
            DatabaseConnectionDeleteRequest(connectionID: connection.id))
        #expect(blockedRetry.error?.category == .timeout)
        #expect(await disconnectGate.entryCount() == 0)
        await cancellationGate.releaseAll()
        let completedDeleteTask = Task {
            await deleteExecutor.deleteConnection(
                DatabaseConnectionDeleteRequest(connectionID: connection.id))
        }
        await disconnectGate.waitForEntries()
        #expect(try await fixture.store.connection(id: connection.id) != nil)
        await disconnectGate.releaseAll()
        await terminalGate.releaseAll()

        #expect(await connectTask.value.status == .failed)
        #expect(await completedDeleteTask.value.payload?.deleted == true)
        let invocations = await session.snapshot().invocations
        let cancellationIndex = try #require(
            invocations.firstIndex(
                of: .cancel(DatabaseManagementFixtures.operation(115).operationID)))
        let disconnectionIndex = try #require(invocations.firstIndex(of: .disconnect))
        #expect(cancellationIndex < disconnectionIndex)
    }

    @Test func terminalizationWinningStillAwaitsServerCancellationBeforeDisconnect() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let connection = try DatabaseManagementFixtures.connection(id: 21)
        let cancellationGate = DatabaseExecutorTestGate(open: false)
        let disconnectGate = DatabaseExecutorTestGate(open: false)
        let cancellingTransitionGate = DatabaseExecutorTestGate(open: false)
        let terminalTransitionGate = DatabaseExecutorTestGate(open: false)
        let (adapter, session) = try DatabaseManagementFixtures.adapter(
            connection: connection,
            gates: DatabaseExecutorTestSessionGates(
                cancel: cancellationGate,
                disconnect: disconnectGate))
        let fixture = try await DatabaseManagementFixtures.make(
            clock: clock,
            adapters: [adapter])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.seedConnection(connection)
        let proxy = DatabaseExecutorMetadataStoreProxy(
            base: fixture.store,
            cancellingTransitionGate: cancellingTransitionGate,
            terminalTransitionGate: terminalTransitionGate)
        let connectExecutor = try DatabaseExecutor(
            metadataStore: proxy,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [adapter],
            currentDate: { clock.read() })
        let operation = DatabaseManagementFixtures.operation(124)
        let connectTask = Task {
            await connectExecutor.connect(
                DatabaseConnectRequest(
                    connectionID: connection.id,
                    operation: operation))
        }
        await terminalTransitionGate.waitForEntries()
        let deleteTask = Task {
            await fixture.executor.deleteConnection(
                DatabaseConnectionDeleteRequest(connectionID: connection.id))
        }
        await cancellationGate.waitForEntries()
        await cancellingTransitionGate.waitForEntries()

        await terminalTransitionGate.releaseAll()
        #expect(await connectTask.value.status == .succeeded)
        await cancellingTransitionGate.releaseAll()
        #expect(await disconnectGate.entryCount() == 0)
        #expect(try await fixture.store.operation(id: operation.operationID)?.state == .succeeded)
        #expect(try await fixture.store.connection(id: connection.id) != nil)

        await cancellationGate.releaseAll()
        await disconnectGate.waitForEntries()
        #expect(try await fixture.store.connection(id: connection.id) != nil)
        await disconnectGate.releaseAll()

        #expect(await deleteTask.value.payload?.deleted == true)
        let invocations = await session.snapshot().invocations
        let cancellationIndex = try #require(
            invocations.firstIndex(of: .cancel(operation.operationID)))
        let disconnectionIndex = try #require(invocations.firstIndex(of: .disconnect))
        #expect(cancellationIndex < disconnectionIndex)
    }

    @Test func noncooperativeDisconnectTimesOutWithoutWedgingManagement() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let connection = try DatabaseManagementFixtures.connection(id: 16)
        let disconnectGate = DatabaseExecutorTestGate(open: false)
        let (adapter, session) = try DatabaseManagementFixtures.adapter(
            connection: connection,
            gates: DatabaseExecutorTestSessionGates(disconnect: disconnectGate))
        let fixture = try await DatabaseManagementFixtures.make(
            clock: clock,
            adapters: [adapter])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.seedConnection(connection)
        let executor = try DatabaseExecutor(
            metadataStore: fixture.store,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [adapter],
            currentDate: { clock.read() },
            managementDrainTimeoutNanoseconds: 50_000_000)
        #expect(
            await executor.connect(
                DatabaseConnectRequest(
                    connectionID: connection.id,
                    operation: DatabaseManagementFixtures.operation(116))
            ).status == .succeeded)
        let timedOutTask = Task {
            await executor.deleteConnection(
                DatabaseConnectionDeleteRequest(connectionID: connection.id))
        }
        await disconnectGate.waitForEntries()

        #expect(await timedOutTask.value.error?.category == .timeout)
        #expect(try await fixture.store.connection(id: connection.id) != nil)
        let blockedRetry = await executor.deleteConnection(
            DatabaseConnectionDeleteRequest(connectionID: connection.id))
        #expect(blockedRetry.error?.category == .timeout)
        #expect(try await fixture.store.connection(id: connection.id) != nil)
        #expect(await executor.managementRetainedCoordinationCount() == 1)
        #expect(await executor.managementRetainedCallbackCount(connectionID: connection.id) == 1)
        let unrelated = try DatabaseManagementFixtures.connection(id: 18)
        #expect(
            await executor.saveConnection(
                DatabaseConnectionSaveRequest(connection: unrelated)
            ).status == .succeeded)
        await disconnectGate.releaseAll()
        while await executor.managementDisconnectionCompleted(connectionID: connection.id) == false
        {
            await Task.yield()
        }
        #expect(await session.snapshot().disconnectCount == 1)
        let completedRetry = await executor.deleteConnection(
            DatabaseConnectionDeleteRequest(connectionID: connection.id))
        #expect(completedRetry.payload?.deleted == true)
        #expect(completedRetry.payload?.disconnected == true)
        #expect(try await fixture.store.connection(id: connection.id) == nil)
        #expect(await executor.managementRetainedCoordinationCount() == 0)
    }

    @Test func neverCompletingDisconnectCannotAccumulateCoordinationIdentifiers() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let connection = try DatabaseManagementFixtures.connection(id: 22)
        let disconnectGate = DatabaseExecutorTestGate(open: false)
        let (adapter, session) = try DatabaseManagementFixtures.adapter(
            connection: connection,
            gates: DatabaseExecutorTestSessionGates(disconnect: disconnectGate))
        let fixture = try await DatabaseManagementFixtures.make(
            clock: clock,
            adapters: [adapter])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.seedConnection(connection)
        let executor = try DatabaseExecutor(
            metadataStore: fixture.store,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.owner,
            adapters: [adapter],
            currentDate: { clock.read() },
            managementDrainTimeoutNanoseconds: 10_000_000)
        #expect(
            await executor.connect(
                DatabaseConnectRequest(
                    connectionID: connection.id,
                    operation: DatabaseManagementFixtures.operation(125))
            ).status == .succeeded)
        let firstDelete = Task {
            await executor.deleteConnection(
                DatabaseConnectionDeleteRequest(connectionID: connection.id))
        }
        await disconnectGate.waitForEntries()
        #expect(await firstDelete.value.error?.category == .timeout)

        for id: UInt8 in 126...141 {
            #expect(
                await executor.capabilities(
                    DatabaseCapabilitiesRequest(
                        connectionID: connection.id,
                        operation: DatabaseManagementFixtures.operation(id))
                ).error?.category == .conflict)
        }
        for _ in 0..<4 {
            #expect(
                await executor.deleteConnection(
                    DatabaseConnectionDeleteRequest(connectionID: connection.id)
                ).error?.category == .timeout)
        }

        #expect(await executor.managementRetainedCoordinationCount() == 1)
        #expect(await executor.managementRetainedCallbackCount(connectionID: connection.id) == 1)
        #expect(await session.snapshot().disconnectCount == 1)
        #expect(try await fixture.store.connection(id: connection.id) != nil)
    }

    @Test func editAndRenameExcludeOperationsAdmittedByAnotherExecutor() async throws {
        for mutation in DatabaseManagementConnectionMutation.allCases {
            let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
            let connection = try DatabaseManagementFixtures.connection(id: 17)
            let lifecycleGate = DatabaseExecutorTestGate()
            let disconnectGate = DatabaseExecutorTestGate(open: false)
            let (adapter, session) = try DatabaseManagementFixtures.adapter(
                connection: connection,
                gates: DatabaseExecutorTestSessionGates(
                    lifecycleState: lifecycleGate,
                    disconnect: disconnectGate))
            let fixture = try await DatabaseManagementFixtures.make(
                clock: clock,
                adapters: [adapter])
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            try await fixture.store.seedConnection(connection)
            let peerExecutor = try DatabaseExecutor(
                metadataStore: fixture.store,
                secretStore: fixture.secretStore,
                runtimeOwner: fixture.owner,
                adapters: [adapter],
                currentDate: { clock.read() })
            #expect(
                await peerExecutor.connect(
                    DatabaseConnectRequest(
                        connectionID: connection.id,
                        operation: DatabaseManagementFixtures.operation(
                            mutation == .edit ? 117 : 121))
                ).status == .succeeded)
            let lifecycleEntries = await lifecycleGate.entryCount()
            await lifecycleGate.block()
            let activeTask = Task {
                await peerExecutor.capabilities(
                    DatabaseCapabilitiesRequest(
                        connectionID: connection.id,
                        operation: DatabaseManagementFixtures.operation(
                            mutation == .edit ? 118 : 122)))
            }
            await lifecycleGate.waitForEntries(lifecycleEntries + 1)
            let edited = try DatabaseManagementFixtures.connection(
                id: 17,
                name: mutation.resultName,
                tags: ["edited"])
            let mutationTask = Task {
                switch mutation {
                case .edit:
                    return await fixture.executor.editConnection(
                        DatabaseConnectionEditRequest(
                            connectionID: connection.id,
                            connection: edited)
                    ).status
                case .rename:
                    return await fixture.executor.renameConnection(
                        DatabaseConnectionRenameRequest(
                            connectionID: connection.id,
                            displayName: mutation.resultName)
                    ).status
                }
            }
            await disconnectGate.waitForEntries()

            #expect(try await fixture.store.connection(id: connection.id) == connection)
            let rejected = await peerExecutor.capabilities(
                DatabaseCapabilitiesRequest(
                    connectionID: connection.id,
                    operation: DatabaseManagementFixtures.operation(
                        mutation == .edit ? 119 : 123)))
            #expect(rejected.error?.category == .conflict)
            await lifecycleGate.releaseAll()
            await disconnectGate.releaseAll()

            #expect(await activeTask.value.status == .failed)
            #expect(await mutationTask.value == .succeeded)
            #expect(
                try await fixture.store.connection(id: connection.id)?.displayName
                    == mutation.resultName)
            #expect(await session.snapshot().disconnectCount == 1)
        }
    }
}
