import Foundation
import Testing
@testable import DatabaseCore
@testable import DatabaseEngine

@Suite struct DatabaseEngineLifecycleTests {
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
