import DatabaseCore
import Foundation
import Testing

@testable import DatabaseExtension

@Suite @MainActor
struct DatabaseUICommandsTests {
    @Test func stateAndColumnWritesStayInTheOwnedPreferences() async throws {
        let fixture = try Fixture()
        let commands = fixture.commands()
        let stateData = try #require(
            try await commands.invoke("database.ui.state", payload: Data("{}".utf8)))
        let state = try JSONDecoder().decode(DatabaseUIState.self, from: stateData)
        #expect(state.columns == fixture.columns)
        #expect(state.privateContent)
        let updated = Data(#"{"version":1,"layouts":[]}"#.utf8)
        _ = try await commands.invoke(
            "database.ui.columns", payload: JSONEncoder().encode(DatabaseUIColumns(data: updated)))
        #expect(fixture.columns == updated)
        #expect(fixture.writes == 1)
        #expect(await fixture.sender.requests.isEmpty)
    }

    @Test func malformedAndExcessiveLayoutsCannotReplacePreferences() async throws {
        let fixture = try Fixture()
        let commands = fixture.commands()
        for invalid in [
            Data("{}".utf8), Data(#"{"version":2,"layouts":[]}"#.utf8),
            Data(repeating: 0, count: 4 * 1024 * 1024 + 1),
        ] {
            await #expect(throws: (any Error).self) {
                try await commands.invoke(
                    "database.ui.columns",
                    payload: JSONEncoder().encode(DatabaseUIColumns(data: invalid)))
            }
        }
        #expect(fixture.writes == 0)
    }

    @Test func credentialWritesAndDeletesUseOnlyTheOwnedSecretStore() async throws {
        let fixture = try Fixture()
        let commands = fixture.commands()
        let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
        let secret = Data("synthetic-password".utf8)
        _ = try await commands.invoke(
            "database.ui.credential.store",
            payload: JSONEncoder().encode(
                DatabaseUICredential(reference: reference, secret: secret)))
        #expect(try await fixture.secrets.read(reference) == secret)
        #expect(
            try await commands.invoke("database.ui.credential.read", payload: Data("{}".utf8))
                == nil)
        _ = try await commands.invoke(
            "database.ui.credential.delete",
            payload: JSONEncoder().encode(DatabaseUICredential(reference: reference, secret: nil)))
        #expect(await fixture.secrets.contains(reference) == false)
        #expect(await fixture.sender.requests.isEmpty)
    }

    @Test func credentialsRejectInternalPurposesExcessiveBytesAndInvalidDeleteBodies() async throws
    {
        let fixture = try Fixture()
        let commands = fixture.commands()
        for request in [
            DatabaseUICredential(
                reference: .init(identifier: UUID(), purpose: .confirmationSigningKey),
                secret: Data("synthetic".utf8)),
            DatabaseUICredential(
                reference: .init(identifier: UUID(), purpose: .password),
                secret: Data(
                    repeating: 0, count: DatabaseSecretStorageLimits.defaultMaximumBytes + 1)),
            DatabaseUICredential(
                reference: .init(identifier: UUID(), purpose: .password), secret: nil),
        ] {
            await #expect(throws: DatabaseBrokerCommandClientError.invalidRequest) {
                try await commands.invoke(
                    "database.ui.credential.store", payload: JSONEncoder().encode(request))
            }
            #expect(await fixture.secrets.contains(request.reference) == false)
        }
        let request = DatabaseUICredential(
            reference: .init(identifier: UUID(), purpose: .password), secret: Data("synthetic".utf8)
        )
        await #expect(throws: DatabaseBrokerCommandClientError.invalidRequest) {
            try await commands.invoke(
                "database.ui.credential.delete", payload: JSONEncoder().encode(request))
        }
    }

    @Test func forwardingLoadsTheOwnedConnectionBeforePreparingItsRoute() async throws {
        let fixture = try Fixture()
        let commands = fixture.commands()
        _ = try await commands.invoke(
            "database.ui.prepare",
            payload: JSONEncoder().encode(
                DatabaseConnectionGetRequest(connectionID: fixture.connection.id)))
        #expect(fixture.prepared == [fixture.connection.id])
        let requests = await fixture.sender.requests
        #expect(requests.count == 1)
        #expect(requests.first?.connectionGetRequest?.connectionID == fixture.connection.id)
    }

    @Test func unknownConnectionsCannotPrepareArbitraryRoutes() async throws {
        let fixture = try Fixture()
        let commands = fixture.commands()
        await #expect(throws: DatabaseBrokerCommandClientError.invalidRequest) {
            try await commands.invoke(
                "database.ui.prepare",
                payload: JSONEncoder().encode(DatabaseConnectionGetRequest(connectionID: .init())))
        }
        #expect(fixture.prepared.isEmpty)
    }

    @Test func repairAndStateRejectUnownedInputFields() async throws {
        let fixture = try Fixture()
        let commands = fixture.commands()
        for command in ["database.ui.state", "database.ui.repair"] {
            await #expect(throws: DatabaseBrokerCommandClientError.invalidRequest) {
                try await commands.invoke(
                    command, payload: Data(#"{"path":"/synthetic/elsewhere"}"#.utf8))
            }
        }
        _ = try await commands.invoke("database.ui.repair", payload: Data("{}".utf8))
        #expect(await fixture.sender.repairs == 1)
    }

    @Test func cancelledWritesDoNotMutatePreferencesOrCredentials() async throws {
        let fixture = try Fixture()
        let commands = fixture.commands()
        let task = Task {
            try await commands.invoke(
                "database.ui.columns",
                payload: JSONEncoder().encode(DatabaseUIColumns(data: fixture.columns!)))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.writes == 0)
    }

    @MainActor private final class Fixture {
        let connection: DatabaseConnectionDefinition
        let sender: Sender
        let secrets: InMemoryDatabaseSecretStore
        var columns: Data? = Data(#"{"version":1,"layouts":[]}"#.utf8)
        var writes = 0
        var prepared: [DatabaseConnectionID] = []

        init() throws {
            connection = try DatabaseConnectionDraft(
                displayName: "Synthetic records", product: .sqlite,
                path: "/synthetic/records.sqlite"
            ).definition()
            sender = Sender(connection: connection)
            secrets = try InMemoryDatabaseSecretStore()
        }

        func commands() -> DatabaseUICommands {
            let secrets = secrets
            let sender = sender
            return DatabaseUICommands(
                sender: sender, readColumns: { self.columns },
                writeColumns: {
                    self.columns = $0; self.writes += 1
                }, privateContent: { true }, credentials: { secrets },
                prepare: { self.prepared.append($0.id) }, repair: { await sender.repair() })
        }
    }

    private actor Sender: DatabaseBrokerCommandSending {
        let connection: DatabaseConnectionDefinition
        var requests: [DatabaseBrokerCommandRequest] = []
        var repairs = 0

        init(connection: DatabaseConnectionDefinition) { self.connection = connection }

        func send(_ request: DatabaseBrokerCommandRequest) throws -> DatabaseBrokerCommandResponse {
            requests.append(request)
            guard request.connectionGetRequest?.connectionID == connection.id else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            return .connectionGet(
                .success(
                    DatabaseConnectionGetResult(connection: connection),
                    metadata: DatabaseResultMetadata(
                        completeness: DatabaseResultCompleteness(state: .complete))))
        }

        func repair() { repairs += 1 }
    }
}
