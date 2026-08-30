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
        let owner = DatabaseRuntimeOwnerToken(rawValue: uuid(250))
        _ = try await store.claimRuntimeOwner(
            owner,
            claimedAt: clock.read().addingTimeInterval(-1))
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
        try await fixture.store.saveConnection(connection)
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
        try await fixture.store.saveConnection(connection)
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
        try await fixture.store.saveConnection(connection)

        #expect(
            await fixture.executor.connection(
                DatabaseConnectionGetRequest(connectionID: connection.id)
            ).error?.category == .internalFailure)
        #expect(
            await fixture.executor.connections(
                DatabaseConnectionListRequest()
            ).error?.category == .internalFailure)

        let validConnection = try DatabaseManagementFixtures.connection(id: 6)
        try await fixture.store.saveConnection(validConnection)
        let query = DatabaseManagementFixtures.query(
            id: 42,
            connectionID: validConnection.id,
            language: .redisCommand,
            text: "GET orders")
        try await fixture.store.saveQuery(query)
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
            connectionGate: gate)
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
        await gate.releaseAll()

        #expect(await saveTask.value.error?.category == .conflict)
        #expect(try await fixture.store.connection(id: connection.id) == nil)
    }

    @Test func savedQueryListsReadEachConnectionOnce() async throws {
        let clock = DatabaseManagementClock(DatabaseManagementFixtures.initialDate)
        let fixture = try await DatabaseManagementFixtures.make(clock: clock)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connection = try DatabaseManagementFixtures.connection(id: 8)
        try await fixture.store.saveConnection(connection)
        for id: UInt8 in 50...52 {
            try await fixture.store.saveQuery(
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
        try await fixture.store.saveConnection(connection)
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

        _ = try await fixture.store.claimRuntimeOwner(
            fixture.owner,
            claimedAt: clock.read())
        let deleted = await fixture.executor.deleteConnection(
            DatabaseConnectionDeleteRequest(connectionID: connection.id))
        #expect(deleted.payload?.deleted == true)
        #expect(deleted.payload?.disconnected == false)
        #expect(try await fixture.store.connection(id: connection.id) == nil)
    }
}
