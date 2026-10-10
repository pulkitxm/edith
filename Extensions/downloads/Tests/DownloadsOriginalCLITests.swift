import EdithExtensionSupport
import Foundation
import Testing
@testable import DownloadsExtension

@Suite(.serialized) @MainActor struct DownloadsOriginalCLITests {
    @Test func preferencesAndFolderSelectionAreCheckedAndPersistInTheEngine() async throws {
        let fixture = try #require(
            ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"])
        let root = URL(fileURLWithPath: fixture)
        let queue = DownloadWorker(
            file: root.appendingPathComponent("preference-queue.json"), executable: { nil },
            isEnabled: { true })
        let worker = DownloadsWorker(queue: queue, start: false)
        let bridge = DownloadsUIBridge(invoke: {
            try await DownloadsUIBridge.execute($0, payload: $1, worker: worker)
        })
        try await bridge.perform(.init(action: "kind", kind: .video))
        #expect(try await bridge.configuration().kind == .video)
        let folder = root.appendingPathComponent("synthetic-audio")
        try await bridge.perform(.init(action: "audioFolder", directory: folder))
        #expect(try await bridge.configuration().directories[DownloadKind.audio.rawValue] == folder)
        await #expect(throws: ExtensionPeerError.self) {
            try await bridge.perform(
                .init(action: "audioFolder", directory: URL(fileURLWithPath: "/private")))
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await bridge.perform(.init(action: "kind"))
        }
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) { _ = try await bridge.configuration() }
    }

    @Test func originalQueueCommandsPreservePlansAndChangeOnlyOwnedHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        let worker = DownloadWorker(file: file, executable: { nil }, isEnabled: { true })
        try await worker.start()
        let added = try await DownloadsCLIExecution.run(
            .init(arguments: [
                "add", "https://synthetic.example.invalid/video", "--kind", "video", "--directory",
                root.path, "--json",
            ]), worker: worker)
        #expect(added.exitCode == 0 && added.stderr.isEmpty)
        #expect(await worker.snapshot().records.count == 1)
        let listing = try await DownloadsCLIExecution.run(
            .init(arguments: ["ls", "--json"]), worker: worker)
        let records = try #require(
            JSONSerialization.jsonObject(with: Data(listing.stdout.utf8)) as? [[String: Any]])
        #expect(records.count == 1 && records[0]["index"] as? Int == 1)
        let preview = try await DownloadsCLIExecution.run(
            .init(arguments: ["rm", "1", "--json"]), worker: worker)
        #expect(preview.exitCode == 0)
        #expect(await worker.snapshot().records.count == 1)
        let removed = try await DownloadsCLIExecution.run(
            .init(arguments: ["rm", "1", "--yes", "--json"]), worker: worker)
        #expect(removed.exitCode == 0)
        #expect(await worker.snapshot().records.isEmpty)
        #expect(DownloadQueue.load(from: file).isEmpty)
        let invalid = try await DownloadsCLIExecution.run(
            .init(arguments: ["rm", "99"]), worker: worker)
        #expect(invalid.exitCode != 0 && !invalid.stderr.isEmpty)
        let help = try await DownloadsCLIExecution.run(.init(arguments: ["--help"]), worker: worker)
        #expect(help.exitCode == 0 && help.stdout.contains("retry") && help.stdout.contains("tool"))
        await worker.stop()
    }
}
