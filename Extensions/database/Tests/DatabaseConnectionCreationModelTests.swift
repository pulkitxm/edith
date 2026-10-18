import Foundation
import Testing

@testable import DatabaseExtension
@testable import DatabaseCore

@MainActor
@Suite("Database connection creation")
struct DatabaseConnectionCreationModelTests {
    @Test("A full connection URL fills the advanced fields")
    func connectionURL() throws {
        let model = DatabaseConnectionCreationModel(
            sender: DatabaseConnectionCreationSender(testSucceeds: true),
            secretStore: try InMemoryDatabaseSecretStore())

        model.updateConnectionURL(
            "postgresql://owner:p%40ss@db.example.com:6432/app?sslmode=require")
        model.applyConnectionURL()

        #expect(model.urlImportPhase == .applied)
        #expect(model.connectionURL.isEmpty)
        #expect(model.product == .postgresql)
        #expect(model.displayName == "app")
        #expect(model.host == "db.example.com")
        #expect(model.port == "6432")
        #expect(model.username == "owner")
        #expect(model.password == "p@ss")
        #expect(model.database == "app")
        #expect(model.tlsEnabled)
    }

    @Test("An Elasticsearch HTTP URL uses the selected product")
    func elasticsearchConnectionURL() throws {
        let model = DatabaseConnectionCreationModel(
            sender: DatabaseConnectionCreationSender(testSucceeds: true),
            secretStore: try InMemoryDatabaseSecretStore())

        model.selectProduct(.elasticsearch)
        model.updateConnectionURL("http://127.0.0.1:59200")
        model.applyConnectionURL()

        #expect(model.urlImportPhase == .applied)
        #expect(model.product == .elasticsearch)
        #expect(model.displayName == "127.0.0.1")
        #expect(model.host == "127.0.0.1")
        #expect(model.port == "59200")
        #expect(model.username.isEmpty)
        #expect(model.password.isEmpty)
        #expect(!model.tlsEnabled)
    }

    @Test("An OpenSearch URL uses the selected product")
    func openSearchConnectionURL() throws {
        let model = DatabaseConnectionCreationModel(
            sender: DatabaseConnectionCreationSender(testSucceeds: true),
            secretStore: try InMemoryDatabaseSecretStore())

        model.selectProduct(.openSearch)
        model.updateConnectionURL("http://127.0.0.1:59201")
        model.applyConnectionURL()

        #expect(model.urlImportPhase == .applied)
        #expect(model.product == .openSearch)
        #expect(model.displayName == "127.0.0.1")
        #expect(model.host == "127.0.0.1")
        #expect(model.port == "59201")
        #expect(!model.tlsEnabled)
    }

    @Test("A ClickHouse URL fills the analytical connection fields")
    func clickHouseConnectionURL() throws {
        let model = DatabaseConnectionCreationModel(
            sender: DatabaseConnectionCreationSender(testSucceeds: true),
            secretStore: try InMemoryDatabaseSecretStore())

        model.selectProduct(.clickHouse)
        model.updateConnectionURL(
            "clickhouse://edith:secret@127.0.0.1:58123/analytics")
        model.applyConnectionURL()

        #expect(model.urlImportPhase == .applied)
        #expect(model.product == .clickHouse)
        #expect(model.displayName == "analytics")
        #expect(model.host == "127.0.0.1")
        #expect(model.port == "58123")
        #expect(model.username == "edith")
        #expect(model.password == "secret")
        #expect(model.database == "analytics")
        #expect(model.supportsTLS)
        #expect(model.usernameRequired)
    }

    @Test("A MySQL URL fills the relational connection fields")
    func mysqlConnectionURL() throws {
        let model = DatabaseConnectionCreationModel(
            sender: DatabaseConnectionCreationSender(testSucceeds: true),
            secretStore: try InMemoryDatabaseSecretStore())

        model.updateConnectionURL(
            "mysql://edith:secret@127.0.0.1:53306/app?ssl-mode=REQUIRED")
        model.applyConnectionURL()

        #expect(model.urlImportPhase == .applied)
        #expect(model.product == .mysql)
        #expect(model.displayName == "app")
        #expect(model.port == "53306")
        #expect(model.username == "edith")
        #expect(model.password == "secret")
        #expect(model.database == "app")
        #expect(model.supportsTLS)
        #expect(model.usernameRequired)
    }

    @Test("Development connections allow guarded data changes by default")
    func developmentDefaults() throws {
        let model = DatabaseConnectionCreationModel(
            sender: DatabaseConnectionCreationSender(testSucceeds: true),
            secretStore: try InMemoryDatabaseSecretStore())

        #expect(model.environmentKind == .development)
        #expect(model.environmentProtection == .confirmationRequired)
        #expect(model.readOnlyPolicy == .disabled)
        #expect(model.productionPolicy == .requireMutationPreview)

        model.selectEnvironment(.production)

        #expect(model.readOnlyPolicy == .required)
        #expect(model.productionPolicy == .prohibitMutations)

        model.selectEnvironment(.staging)

        #expect(model.readOnlyPolicy == .disabled)
        #expect(model.productionPolicy == .requireMutationPreview)
    }

    @Test("A URL can be tested and saved in one action")
    func testAndSaveURL() async throws {
        let sender = DatabaseConnectionCreationSender(testSucceeds: true)
        let model = DatabaseConnectionCreationModel(
            sender: sender,
            secretStore: try InMemoryDatabaseSecretStore())
        model.updateConnectionURL("postgresql://edith@127.0.0.1:55432/app")

        let saved = await model.testAndSaveConnection(applyPendingURL: true)

        #expect(saved?.displayName == "app")
        #expect(saved?.readOnlyPolicy == .disabled)
        #expect(model.phase == .saved)
        #expect((await sender.recordedRequests()).count == 2)
    }

    @Test("Manual entry ignores a hidden connection URL")
    func manualEntryIgnoresHiddenURL() async throws {
        let sender = DatabaseConnectionCreationSender(testSucceeds: true)
        let model = DatabaseConnectionCreationModel(
            sender: sender,
            secretStore: try InMemoryDatabaseSecretStore())
        model.displayName = "Manual database"
        model.host = "manual.example.com"
        model.port = "5432"
        model.username = "edith"
        model.database = "manual"
        model.updateConnectionURL("postgresql://other@hidden.example.com/hidden")

        let saved = await model.testAndSaveConnection(applyPendingURL: false)

        let connection = try #require(saved)
        guard case .network(let endpoints) = connection.location else {
            Issue.record("Expected a network connection.")
            return
        }
        #expect(connection.displayName == "Manual database")
        #expect(endpoints.first?.host == "manual.example.com")
        #expect(connection.namespaces.database == "manual")
        #expect(model.connectionURL.contains("hidden.example.com"))
    }

    @Test("A tested connection can be saved with its Keychain reference")
    func testAndSave() async throws {
        let sender = DatabaseConnectionCreationSender(testSucceeds: true)
        let store = try InMemoryDatabaseSecretStore()
        let model = DatabaseConnectionCreationModel(
            sender: sender,
            secretStore: store,
            currentDate: { Date(timeIntervalSince1970: 4_000) })
        model.displayName = "TUF PostgreSQL"
        model.host = "127.0.0.1"
        model.port = "15432"
        model.username = "edith"
        model.database = "million_rows"
        model.password = "secret"

        await model.testConnection()

        guard case .tested(let detail) = model.phase else {
            Issue.record("Expected a successful connection test.")
            return
        }
        #expect(detail.contains("PostgreSQL 17.4"))
        #expect(model.canSave)

        let saved = await model.saveConnection()

        #expect(saved?.displayName == "TUF PostgreSQL")
        #expect(model.phase == .saved)
        let requests = await sender.recordedRequests()
        #expect(requests.count == 2)
        let tested = try #require(requests[0].connectionTestRequest?.connection)
        let savedRequest = try #require(requests[1].connectionSaveRequest?.connection)
        #expect(tested == savedRequest)
        let reference = try #require(tested.authentication.secretReferences.first)
        #expect(try await store.read(reference) == Data("secret".utf8))
    }

    @Test("Changing tested details requires another test")
    func changedDetailsInvalidateSave() async throws {
        let sender = DatabaseConnectionCreationSender(testSucceeds: true)
        let store = try InMemoryDatabaseSecretStore()
        let model = DatabaseConnectionCreationModel(sender: sender, secretStore: store)
        model.displayName = "PostgreSQL"
        model.username = "edith"

        await model.testConnection()
        #expect(model.canSave)

        model.host = "db.internal"
        model.invalidateTest()

        #expect(!model.canSave)
        #expect(model.phase == .editing)
    }

    @Test("A failed test removes the temporary credential")
    func failedTestCleansCredential() async throws {
        let sender = DatabaseConnectionCreationSender(testSucceeds: false)
        let store = try InMemoryDatabaseSecretStore()
        let model = DatabaseConnectionCreationModel(sender: sender, secretStore: store)
        model.displayName = "PostgreSQL"
        model.username = "edith"
        model.password = "wrong"

        await model.testConnection()

        guard case .failed(let detail) = model.phase else {
            Issue.record("Expected a failed connection test.")
            return
        }
        #expect(detail == "Database authentication failed.")
        let request = try #require((await sender.recordedRequests()).first)
        let reference = try #require(
            request.connectionTestRequest?.connection.authentication.secretReferences.first)
        await #expect(throws: DatabaseSecretStoreError.notFound(reference)) {
            try await store.read(reference)
        }
    }

    @Test("Closing creator admission rejects new work synchronously")
    func closedAdmission() async throws {
        let sender = DatabaseConnectionCreationSender(testSucceeds: true)
        let model = DatabaseConnectionCreationModel(
            sender: sender, secretStore: try InMemoryDatabaseSecretStore())
        model.displayName = "Synthetic database"
        model.username = "synthetic"
        model.cancelPendingCommands()

        model.selectEnvironment(.production)
        model.updateConnectionURL("postgresql://synthetic@127.0.0.1/example")
        await model.testConnection()
        let saved = await model.saveConnection()
        let combined = await model.testAndSaveConnection(applyPendingURL: true)
        await model.cancelAndWait()

        #expect(!model.canTest)
        #expect(!model.canApplyConnectionURL)
        #expect(!model.canSave)
        #expect(saved == nil)
        #expect(combined == nil)
        #expect(model.phase == .editing)
        #expect(model.environmentKind == .development)
        #expect(model.connectionURL.isEmpty)
        #expect((await sender.recordedRequests()).isEmpty)
        #expect(model.isDrained)
    }

    @Test("Drain joins secret storage and deletion after cancellation")
    func secretSynchronizationDrain() async throws {
        let storing = DatabaseCreationOwnershipGate()
        let deleting = DatabaseCreationOwnershipGate()
        let store = DatabaseCreationOwnershipStore(storing: storing, deleting: deleting)
        let sender = DatabaseConnectionCreationSender(testSucceeds: true)
        let model = DatabaseConnectionCreationModel(sender: sender, secretStore: store)
        model.displayName = "Synthetic database"
        model.username = "synthetic"
        model.password = "synthetic credential"
        let testing = Task { await model.testConnection() }
        await storing.waitUntilEntered()
        model.cancelPendingCommands()
        let draining = Task { await model.cancelAndWait() }
        let secondDrain = Task { await model.discardUnsavedCredential() }
        await storing.waitUntilCancelled()

        #expect(!model.isDrained)
        #expect((await sender.recordedRequests()).isEmpty)
        #expect(await store.deleteCount() == 0)
        await storing.release()
        await deleting.waitUntilEntered()

        #expect(!model.isDrained)
        #expect(await store.deleteCount() == 1)
        #expect((await sender.recordedRequests()).isEmpty)
        await deleting.release()
        await testing.value
        await draining.value
        await secondDrain.value

        #expect(model.isDrained)
        #expect(model.phase == .editing)
        #expect(await store.deleteCount() == 1)
        #expect(await store.valueCount() == 0)
    }

    @Test("Drain retains a noncooperative test until its real response")
    func testResponseDrain() async throws {
        let gate = DatabaseCreationOwnershipGate()
        let store = DatabaseCreationOwnershipStore()
        let sender = DatabaseCreationOwnershipSender(testing: gate)
        let model = DatabaseConnectionCreationModel(sender: sender, secretStore: store)
        model.displayName = "Synthetic database"
        model.username = "synthetic"
        model.password = "synthetic credential"
        let testing = Task { await model.testConnection() }
        await gate.waitUntilEntered()
        model.cancelPendingCommands()
        let draining = Task { await model.cancelAndWait() }
        await gate.waitUntilCancelled()

        #expect(!model.isDrained)
        #expect(await store.valueCount() == 1)
        #expect(await store.deleteCount() == 0)
        await model.testConnection()
        #expect((await sender.recordedRequests()).count == 1)
        await gate.release()
        await testing.value
        await draining.value

        #expect(model.phase == .editing)
        #expect(model.isDrained)
        #expect(await store.valueCount() == 0)
        #expect(await store.deleteCount() == 1)
    }

    @Test("A committed save survives cancellation and repeated cleanup")
    func successfulSaveAfterCancellation() async throws {
        let gate = DatabaseCreationOwnershipGate()
        let store = DatabaseCreationOwnershipStore()
        let sender = DatabaseCreationOwnershipSender(saving: gate)
        let model = DatabaseConnectionCreationModel(sender: sender, secretStore: store)
        model.displayName = "Synthetic production database"
        model.username = "synthetic"
        model.password = "synthetic credential"
        model.selectEnvironment(.production)
        await model.testConnection()
        #expect(model.canSave)
        let saving = Task { await model.saveConnection() }
        await gate.waitUntilEntered()
        model.cancelPendingCommands()
        let draining = Task { await model.cancelAndWait() }
        let cleanup = Task { await model.discardUnsavedCredential() }
        await gate.waitUntilCancelled()

        #expect(!model.isDrained)
        #expect(model.phase == .saving)
        #expect(await store.deleteCount() == 0)
        await gate.release()
        let saved = try #require(await saving.value)
        await draining.value
        await cleanup.value
        await model.discardUnsavedCredential()
        model.invalidateTest()
        model.selectEnvironment(.development)
        await model.testConnection()

        #expect(model.isDrained)
        #expect(model.phase == .saved)
        #expect(model.savedConnection == saved)
        #expect(saved.environment.kind == .production)
        #expect(saved.environment.protection == .confirmationRequired)
        #expect(saved.readOnlyPolicy == .required)
        #expect(saved.productionPolicy == .prohibitMutations)
        #expect(model.environmentKind == .production)
        #expect((await sender.recordedRequests()).count == 2)
        let reference = try #require(saved.authentication.secretReferences.first)
        #expect(try await store.read(reference) == Data("synthetic credential".utf8))
        #expect(await store.deleteCount() == 0)
    }

    @Test("An unsuccessful save is joined before temporary credential cleanup")
    func unsuccessfulSaveDrain() async throws {
        let gate = DatabaseCreationOwnershipGate()
        let store = DatabaseCreationOwnershipStore()
        let sender = DatabaseCreationOwnershipSender(saving: gate, saveSucceeds: false)
        let model = DatabaseConnectionCreationModel(sender: sender, secretStore: store)
        model.displayName = "Synthetic database"
        model.username = "synthetic"
        model.password = "synthetic credential"
        await model.testConnection()
        let saving = Task { await model.saveConnection() }
        await gate.waitUntilEntered()
        let draining = Task { await model.cancelAndWait() }
        await gate.waitUntilCancelled()

        #expect(!model.isDrained)
        #expect(await store.deleteCount() == 0)
        await gate.release()
        #expect(await saving.value == nil)
        await draining.value

        #expect(model.isDrained)
        #expect(model.savedConnection == nil)
        #expect(await store.valueCount() == 0)
        #expect(await store.deleteCount() == 1)
        guard case .failed = model.phase else {
            Issue.record("Expected the actual failed save result.")
            return
        }
    }

    @Test("Page session retains replaced creators and closes later creators")
    func sessionCreatorOwnership() async throws {
        let gate = DatabaseCreationOwnershipGate()
        let store = DatabaseCreationOwnershipStore()
        let sender = DatabaseCreationOwnershipSender(saving: gate)
        let session = DatabasePageSession(
            sender: sender, repair: {}, prepare: { _ in }, secretStore: store)
        weak var retained: DatabaseConnectionCreationModel?
        var creator: DatabaseConnectionCreationModel? = session.connectionCreation()
        retained = creator
        creator?.displayName = "Synthetic database"
        creator?.username = "synthetic"
        creator?.password = "synthetic credential"
        await creator?.testConnection()
        let saving = Task { [model = try #require(creator)] in await model.saveConnection() }
        await gate.waitUntilEntered()
        creator = nil
        let replacement = session.connectionCreation()
        session.cancelPendingCommands()
        let draining = Task { await session.cancelAndWait() }
        await gate.waitUntilCancelled()
        let late = session.connectionCreation()
        await late.testConnection()

        #expect(retained != nil)
        #expect(!replacement.canTest)
        #expect(!late.canTest)
        #expect((await sender.recordedRequests()).count == 2)
        #expect(await store.deleteCount() == 0)
        await gate.release()
        let saved = try #require(await saving.value)
        await draining.value

        let reference = try #require(saved.authentication.secretReferences.first)
        #expect(try await store.read(reference) == Data("synthetic credential".utf8))
        #expect(await store.deleteCount() == 0)
        #expect(replacement.isDrained)
    }

}

private actor DatabaseConnectionCreationSender: DatabaseBrokerCommandSending {
    private let testSucceeds: Bool
    private var requests: [DatabaseBrokerCommandRequest] = []

    init(testSucceeds: Bool) {
        self.testSucceeds = testSucceeds
    }

    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        requests.append(request)
        let metadata = DatabaseResultMetadata(
            completeness: DatabaseResultCompleteness(state: .complete))
        switch request {
        case .connectionTest(let testRequest):
            if !testSucceeds {
                return .connectionTest(
                    .failure(
                        DatabaseErrorEnvelope(
                            category: .authenticationFailed,
                            message: "Database authentication failed."),
                        metadata: metadata))
            }
            let identity = DatabaseProductIdentity(
                product: testRequest.connection.productHint,
                version: DatabaseVersion(string: "17.4"),
                topology: DatabaseTopology(kind: .standalone))
            let capabilities = DatabaseCapabilityReport(
                productIdentity: identity,
                capabilities: [],
                discoveredAt: Date(timeIntervalSince1970: 4_000))
            return .connectionTest(
                .success(
                    DatabaseConnectionTestResult(
                        connection: testRequest.connection.identity,
                        productIdentity: identity,
                        capabilities: capabilities,
                        latencyMilliseconds: 9,
                        testedAt: Date(timeIntervalSince1970: 4_000)),
                    metadata: metadata))
        case .connectionSave(let saveRequest):
            return .connectionSave(
                .success(
                    DatabaseConnectionSaveResult(connection: saveRequest.connection),
                    metadata: metadata))
        default:
            throw DatabaseBrokerCommandClientError.invalidRequest
        }
    }

    func recordedRequests() -> [DatabaseBrokerCommandRequest] {
        requests
    }
}

private actor DatabaseCreationOwnershipGate {
    private var entered = false
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelledWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered = true
                for waiter in enteredWaiters { waiter.resume() }
                enteredWaiters.removeAll()
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancelledWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    private func recordCancellation() {
        cancelled = true
        for waiter in cancelledWaiters { waiter.resume() }
        cancelledWaiters.removeAll()
    }
}

private actor DatabaseCreationOwnershipSender: DatabaseBrokerCommandSending {
    private let responder = DatabaseConnectionCreationSender(testSucceeds: true)
    private let testing: DatabaseCreationOwnershipGate?
    private let saving: DatabaseCreationOwnershipGate?
    private let saveSucceeds: Bool
    private var requests: [DatabaseBrokerCommandRequest] = []

    init(
        testing: DatabaseCreationOwnershipGate? = nil,
        saving: DatabaseCreationOwnershipGate? = nil,
        saveSucceeds: Bool = true
    ) {
        self.testing = testing
        self.saving = saving
        self.saveSucceeds = saveSucceeds
    }

    func send(_ request: DatabaseBrokerCommandRequest) async throws -> DatabaseBrokerCommandResponse
    {
        requests.append(request)
        switch request {
        case .connectionTest:
            await testing?.hold()
        case .connectionSave:
            await saving?.hold()
            if !saveSucceeds {
                return .connectionSave(
                    .failure(
                        DatabaseErrorEnvelope(
                            category: .authenticationFailed, message: "Synthetic save failed."),
                        metadata: DatabaseResultMetadata(
                            completeness: DatabaseResultCompleteness(state: .complete))))
            }
        default:
            throw DatabaseBrokerCommandClientError.invalidRequest
        }
        return try await responder.send(request)
    }

    func recordedRequests() -> [DatabaseBrokerCommandRequest] { requests }
}

private actor DatabaseCreationOwnershipStore: DatabaseSecretStore {
    private let storing: DatabaseCreationOwnershipGate?
    private let deleting: DatabaseCreationOwnershipGate?
    private var values: [DatabaseSecretReference: Data] = [:]
    private var deletions = 0

    init(
        storing: DatabaseCreationOwnershipGate? = nil,
        deleting: DatabaseCreationOwnershipGate? = nil
    ) {
        self.storing = storing
        self.deleting = deleting
    }

    func store(_ secret: Data, for reference: DatabaseSecretReference) async {
        await storing?.hold()
        values[reference] = secret
    }

    func storeIfAbsent(_ secret: Data, for reference: DatabaseSecretReference) async -> Data {
        if let value = values[reference] { return value }
        await store(secret, for: reference)
        return secret
    }

    func read(_ reference: DatabaseSecretReference) throws -> Data {
        guard let value = values[reference] else {
            throw DatabaseSecretStoreError.notFound(reference)
        }
        return value
    }

    func delete(_ reference: DatabaseSecretReference) async {
        deletions += 1
        await deleting?.hold()
        values[reference] = nil
    }

    func contains(_ reference: DatabaseSecretReference) -> Bool { values[reference] != nil }
    func deleteCount() -> Int { deletions }
    func valueCount() -> Int { values.count }
}
