import Foundation
import Testing

@testable import Edith
@testable import EdithDatabase

@MainActor
@Suite("Database connection creation")
struct DatabaseConnectionCreationModelTests {
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
