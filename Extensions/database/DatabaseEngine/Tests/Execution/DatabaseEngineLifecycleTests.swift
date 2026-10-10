import Foundation
import Testing
@testable import DatabaseCore
@testable import DatabaseEngine

@Suite struct DatabaseEngineLifecycleTests {
    @Test func ownedRuntimeConnectsQueriesAndDisconnectsSQLite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = DatabaseEngine(
            metadataFile: root.appendingPathComponent("metadata.sqlite"),
            secretStore: { try InMemoryDatabaseSecretStore() }, adapters: { [SQLiteDatabaseAdapter()] })
        let definition = try DatabaseConnectionDraft(
            displayName: "Synthetic SQLite", product: .sqlite,
            path: root.appendingPathComponent("synthetic.sqlite").path,
            environmentKind: .testing, environmentLabel: "Synthetic",
            environmentProtection: .standard, readOnlyPolicy: .disabled,
            productionPolicy: .standard).definition()
        _ = try await engine.send(.connectionSave(.init(connection: definition)))
        let connected = try await engine.send(.connect(.init(connectionID: definition.id)))
        guard case .connect(let result) = connected else {
            Issue.record("Connect returned an unexpected result")
            await engine.shutdown()
            return
        }
        #expect(result.payload != nil)
        let queried = try await engine.send(.query(.init(
            target: .init(connectionID: definition.id), language: .sql,
            command: "SELECT 'synthetic-value' AS result")))
        #expect(String(decoding: try JSONEncoder().encode(queried), as: UTF8.self)
            .contains("synthetic-value"))
        let disconnected = try await engine.send(.disconnect(.init(connectionID: definition.id)))
        guard case .disconnect(let result) = disconnected else {
            Issue.record("Disconnect returned an unexpected result")
            await engine.shutdown()
            return
        }
        #expect(result.payload?.disconnected == true)
        await engine.shutdown()
    }

    @Test func ownedRuntimeReleasesMetadataAndRejectsStoppedCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = DatabaseEngine(
            metadataFile: root.appendingPathComponent("metadata.sqlite"),
            secretStore: { try InMemoryDatabaseSecretStore() }, adapters: { [SQLiteDatabaseAdapter()] })
        #expect(await engine.isRunning == false)
        let response = try await engine.send(.connectionList(.init()))
        guard case .connectionList(let result) = response else {
            Issue.record("Connection list returned an unexpected result")
            return
        }
        #expect(result.payload?.connections.isEmpty == true)
        #expect(await engine.isRunning)
        await engine.shutdown()
        #expect(await engine.isRunning == false)
        await #expect(throws: DatabaseEngineError.stopped) {
            try await engine.send(.connectionList(.init()))
        }
        let fresh = DatabaseEngine(
            metadataFile: root.appendingPathComponent("metadata.sqlite"),
            secretStore: { try InMemoryDatabaseSecretStore() }, adapters: { [SQLiteDatabaseAdapter()] })
        _ = try await fresh.send(.connectionList(.init()))
        #expect(await fresh.isRunning)
        await fresh.shutdown()
    }

    @Test func shutdownBeforeStartCreatesNoMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = DatabaseEngine(root: root)
        await engine.shutdown()
        await #expect(throws: DatabaseEngineError.stopped) {
            try await engine.send(.connectionList(.init()))
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
