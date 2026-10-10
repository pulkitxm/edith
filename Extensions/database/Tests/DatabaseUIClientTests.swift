import DatabaseCore
import EdithExtensionSupport
import Foundation
import Testing

@testable import DatabaseExtension

@Suite @MainActor
struct DatabaseUIClientTests {
    @Test func originalWorkspaceModelsUseOnlyTheAdmittedEngine() async throws {
        let fixture = Fixture()
        await fixture.client.load()
        #expect(fixture.client.loaded)
        #expect(!fixture.client.privateContent)
        let session = fixture.client.makeSession()
        await session.page.refresh()
        await session.connections.loadConnections()
        #expect(session.page.readiness == .ready)
        #expect(fixture.bridge.commands == [.connectionList, .connectionList])
        #expect(fixture.bridge.requests.allSatisfy { $0.presentationID == fixture.presentation })
        #expect(
            fixture.bridge.requests.map(\.operation) == [
                "database.ui.state", "database.execute", "database.execute",
            ])
        session.shutdown()
        fixture.client.shutdown()
    }

    @Test func brokerResponsesMustMatchTheirOriginalRequest() async throws {
        let fixture = Fixture()
        await #expect(throws: DatabaseBrokerCommandContractError.self) {
            try await fixture.client.send(.connectionGet(.init(connectionID: .init())))
        }
        #expect(fixture.bridge.commands == [.connectionGet])
    }

    @Test func storedColumnsStayOwnedAndWritesAreAcknowledged() async throws {
        let fixture = Fixture()
        await fixture.client.load()
        let columns = Data(#"{"version":1,"layouts":[]}"#.utf8)
        fixture.client.persistColumns(columns)
        try await fixture.client.flushColumns()
        #expect(
            try JSONSerialization.jsonObject(with: #require(fixture.bridge.columns))
                as? NSDictionary == JSONSerialization.jsonObject(with: columns) as? NSDictionary)
        #expect(
            try JSONSerialization.jsonObject(with: #require(fixture.client.columns))
                as? NSDictionary == JSONSerialization.jsonObject(with: columns) as? NSDictionary)
        #expect(
            fixture.bridge.requests.map(\.operation) == [
                "database.ui.state", "database.ui.columns",
            ])
    }

    @Test func failedColumnWritesRemainPendingUntilExplicitRetry() async throws {
        let fixture = Fixture()
        fixture.bridge.reject = true
        fixture.client.persistColumns(Data(#"{"version":1,"layouts":[]}"#.utf8))
        await #expect(throws: ExtensionEngineError.unavailable) {
            try await fixture.client.flushColumns()
        }
        #expect(fixture.client.failure != nil)
        fixture.bridge.reject = false
        fixture.client.retryColumns()
        try await fixture.client.flushColumns()
        #expect(fixture.client.failure == nil)
        #expect(
            fixture.bridge.requests.map(\.operation) == [
                "database.ui.columns", "database.ui.columns",
            ])
    }

    @Test func privacyFailsClosedWhenTheOwnedEngineIsUnavailable() async throws {
        let fixture = Fixture()
        await fixture.client.load()
        #expect(!fixture.client.privateContent)
        fixture.bridge.reject = true
        await fixture.client.refreshPrivacy()
        #expect(fixture.client.privateContent)
        fixture.bridge.reject = false
        await fixture.client.refreshPrivacy()
        #expect(!fixture.client.privateContent)
    }

    @Test func credentialBridgeHasNoSecretReadOrArbitraryAction() async throws {
        let fixture = Fixture()
        let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
        try await fixture.client.store(Data("synthetic-password".utf8), for: reference)
        try await fixture.client.delete(reference)
        await #expect(throws: DatabaseBrokerCommandClientError.invalidRequest) {
            try await fixture.client.read(reference)
        }
        await #expect(throws: DatabaseBrokerCommandClientError.invalidRequest) {
            try await fixture.client.contains(reference)
        }
        await #expect(throws: DatabaseBrokerCommandClientError.invalidRequest) {
            try await fixture.client.storeIfAbsent(Data(), for: reference)
        }
        #expect(
            fixture.bridge.requests.map(\.operation) == [
                "database.ui.credential.store", "database.ui.credential.delete",
            ])
    }

    @Test func forwardPreparationPassesOnlyTheOwnedConnectionIdentifier() async throws {
        let fixture = Fixture()
        let id = DatabaseConnectionID()
        try await fixture.client.prepare(id)
        let request = try #require(fixture.bridge.requests.first)
        #expect(request.operation == "database.ui.prepare")
        #expect(
            try JSONDecoder().decode(DatabaseConnectionGetRequest.self, from: request.payload)
                .connectionID == id)
    }

    @Test func shutdownInvalidatesTheClientWithoutStartingAnEngine() async throws {
        let fixture = Fixture()
        fixture.client.shutdown()
        await #expect(throws: ExtensionEngineError.unavailable) {
            try await fixture.client.repair()
        }
        #expect(fixture.bridge.requests.isEmpty)
        #expect(fixture.client.privateContent)
    }

    @MainActor private final class Fixture {
        let presentation = UUID()
        let bridge = Bridge()
        let client: DatabaseUIClient
        init() {
            client = DatabaseUIClient(
                engine: ExtensionEngineClient(bridge: bridge, presentationID: presentation)!)
        }
    }

    @MainActor private final class Bridge: NSObject {
        var requests: [ExtensionEngineRequest] = []
        var commands: [DatabaseBrokerCommandKind] = []
        var columns: Data? = Data(#"{"version":1,"layouts":[]}"#.utf8)
        var reject = false

        @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            let request = try! ExtensionEngineWire.decode(ExtensionEngineRequest.self, from: data)
            requests.append(request)
            var payload = Data("{\"ok\":true}".utf8)
            if request.operation == "database.ui.state" {
                payload = try! JSONEncoder().encode(
                    DatabaseUIState(columns: columns, privateContent: false))
            } else if request.operation == "database.ui.privacy" {
                payload = Data("false".utf8)
            } else if request.operation == "database.ui.columns", !reject {
                columns = try! JSONDecoder().decode(DatabaseUIColumns.self, from: request.payload)
                    .data
                payload = try! JSONEncoder().encode(DatabaseUIColumns(data: columns!))
            } else if request.operation == "database.execute" {
                let command = try! JSONDecoder().decode(
                    DatabaseBrokerCommandRequest.self, from: request.payload)
                commands.append(command.kind)
                let response = DatabaseBrokerCommandResponse.connectionList(
                    .success(
                        .init(connections: []),
                        metadata: .init(completeness: .init(state: .complete))))
                payload = try! JSONEncoder().encode(response)
            }
            completion(
                try! ExtensionEngineWire.encode(
                    ExtensionEngineReply(token: request.token, ok: !reject, payload: payload)))
        }

        @objc func cancel(_ token: String) {}
    }
}
