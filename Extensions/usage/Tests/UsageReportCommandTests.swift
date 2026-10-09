import EdithExtensionSupport
import Foundation
import Testing
@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageReportCommandTests {
    @Test func ownedCommandsRejectInjectedPathsAndUnknownPayloadFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in
            throw CancellationError()
        }
        let commands = UsageReportCommands(
            controller: controller, store: .init(url: root.appendingPathComponent("usage.json")),
            directory: root)
        for command in ["usage.status", "usage.summary", "usage.history.export", "usage.refresh"] {
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await commands.execute(
                    command, payload: Data(#"{"path":"/tmp/other"}"#.utf8))
            }
        }
        let state = try await commands.execute("usage.status", payload: Data("{}".utf8))
        #expect(
            (try JSONSerialization.jsonObject(with: state) as? [String: Any])?["refreshing"]
                as? Bool == false)
        await commands.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await commands.execute("usage.status", payload: Data("{}".utf8))
        }
        await controller.shutdown()
    }

    @Test func explicitAttributionResetRequiresConfirmationAndTouchesOnlyOwnedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = UsageAttributionCache.url(dataDir: root); try Data("{}".utf8).write(to: url)
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in
            throw CancellationError()
        }
        let commands = UsageReportCommands(
            controller: controller, store: .init(url: root.appendingPathComponent("usage.json")),
            directory: root)
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await commands.execute("usage.attribution.reset", payload: Data("{}".utf8))
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        _ = try await commands.execute(
            "usage.attribution.reset", payload: Data(#"{"confirm":true}"#.utf8))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await controller.shutdown()
    }
    @Test func shareRepositoryCountRespectsSourcesDatesAndRepositoryIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(
            #"""
            {"defaultSources":["selected"],"daily":[
            {"period":"2026-10-09","projects":[
            {"repositoryID":"sample/repo","bySource":{"selected":{"tokens":12}}},
            {"repositoryID":"sample/repo","bySource":{"selected":{"tokens":2}}},
            {"repositoryID":"sample/other","bySource":{"other":{"tokens":24}}}]},
            {"period":"2026-10-01","projects":[
            {"repositoryID":"sample/older","bySource":{"selected":{"tokens":50}}}]}]}
            """#.utf8)
        try data.write(to: root.appendingPathComponent("usage.json"))
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in
            throw CancellationError()
        }
        let commands = UsageReportCommands(
            controller: controller, store: .init(url: root.appendingPathComponent("usage.json")),
            directory: root)
        var tile = SurfaceTile(.usage)
        #expect(try await commands.repositoryCount(tile: tile, periods: ["2026-10-09"]) == 1)
        tile.sourceIDs = ["other"]
        #expect(try await commands.repositoryCount(tile: tile, periods: ["2026-10-09"]) == 1)
        tile.sourceIDs = []
        #expect(try await commands.repositoryCount(tile: tile, periods: ["2026-10-09"]) == 0)
        await controller.shutdown(); await commands.shutdown()
    }

}
