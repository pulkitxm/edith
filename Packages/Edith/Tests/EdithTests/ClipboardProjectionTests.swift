import Foundation
import Testing

@testable import Edith
@testable import EdithAgent
@testable import EdithKit

@Suite struct ClipboardProjectionTests {
    @Test func failedOptimisticChangesRestoreConfirmedDataWithoutUndoingLaterIntent() {
        let entry = entry("first")
        var history = ClipboardHistoryProjection()
        history.replace([entry])
        let pin = UUID()
        let unpin = UUID()
        history.begin(pin, mutation: .init(.pin, ids: [entry.id]))
        #expect(history.entries.first?.pinned == true)
        history.begin(unpin, mutation: .init(.unpin, ids: [entry.id]))
        #expect(history.entries.first?.pinned == false)
        history.finish(pin, succeeded: false)
        #expect(history.entries.first?.pinned == false)
        history.finish(unpin, succeeded: false)
        #expect(history.entries == [entry])
    }

    @Test func externalSnapshotsRemainVisibleWhileConfirmedDeletionTargetsOnlyItsIDs() {
        let first = entry("first")
        let later = entry("later")
        var history = ClipboardHistoryProjection()
        history.replace([first])
        let deletion = UUID()
        history.begin(deletion, mutation: .init(.delete, ids: [first.id]))
        #expect(history.entries.isEmpty)
        history.replace([first, later])
        #expect(history.entries.map(\.id) == [later.id])
        history.finish(deletion, succeeded: true)
        #expect(history.entries.map(\.id) == [later.id])
    }

    @MainActor @Test func historyViewUsesTheDaemonAndRollsBackWhenItCannotSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clipboard-view-" + UUID().uuidString)
        let suite = "clipboard-view-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite);
            try? FileManager.default.removeItem(at: root)
        }
        let archive = ClipboardArchive(root: root)
        let capture = ClipboardCapture(
            payload: .init(
                data: Data("fixture".utf8), types: ["public.utf8-plain-text"], ext: "txt",
                preview: "fixture"), sourceApp: nil, sourceBundleID: nil)
        _ = try archive.capture(capture, maxItems: 200, maxBytes: 1000, maxAge: nil)
        let runtime = AgentRuntime(build: "clipboard-view", store: nil)
        let service = ClipboardService(archive: archive, defaults: defaults, changed: {})
        await service.register(on: runtime)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let model = ClipboardHistoryModel(client: .init(client: listener.client()))
        model.start()
        defer { model.stop() }
        try await wait { model.entries.count == 1 }
        model.mutate(.init(.pin, ids: [capture.id]))
        #expect(model.entries.first?.pinned == true)
        try await wait { (try? archive.snapshot(.init()).entries.first?.pinned) == true }
        try await wait { !model.isSaving }
        await runtime.shutdown()
        model.mutate(.init(.delete, ids: [capture.id]))
        #expect(model.entries.isEmpty)
        try await wait { model.error != nil && model.entries.count == 1 }
        #expect(model.entries.first?.pinned == true)
    }

    @Test func backupSnapshotsKeepMatchingBlobsWhenLiveHistoryChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clipboard-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = ClipboardArchive(root: root.appendingPathComponent("local"))
        let capture = ClipboardCapture(
            payload: .init(
                data: Data("saved".utf8), types: ["public.utf8-plain-text"], ext: "txt",
                preview: "saved"), sourceApp: nil, sourceBundleID: nil)
        _ = try archive.capture(capture, maxItems: 200, maxBytes: 1000, maxAge: nil)
        let stage = root.appendingPathComponent("stage")
        try archive.stageExport(to: stage)
        _ = try archive.mutate(.init(.delete, ids: [capture.id]))
        let backup = ClipboardArchive(root: stage)
        #expect(try backup.payload(id: capture.id).data == capture.data)
        let restored = ClipboardArchive(root: root.appendingPathComponent("restored"))
        let newer = ClipboardCapture(
            payload: .init(
                data: Data("newer".utf8), types: ["public.utf8-plain-text"], ext: "txt",
                preview: "newer"), sourceApp: nil, sourceBundleID: nil)
        _ = try restored.capture(newer, maxItems: 200, maxBytes: 1000, maxAge: nil)
        let entry = try #require(backup.snapshot(.init()).entries.first)
        let name = entry.sha256 + "." + entry.ext
        try restored.restoreBlob(from: stage.appendingPathComponent("blobs/" + name), name: name)
        try restored.mergeAvailableCloudEntries(from: stage.appendingPathComponent("index.jsonl"))
        #expect(try restored.snapshot(.init()).total == 2)
        #expect(try restored.payload(id: newer.id).data == newer.data)
    }

    @Test func backupIndexesExcludePayloadsOutsideTheCloudStoragePolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clipboard-filtered-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = ClipboardArchive(root: root.appendingPathComponent("local"))
        let large = ClipboardCapture(
            payload: .init(
                data: Data(repeating: 0, count: 1_048_577), types: ["public.png"], ext: "png",
                preview: "image"), sourceApp: nil, sourceBundleID: nil)
        _ = try archive.capture(large, maxItems: 200, maxBytes: 2 << 20, maxAge: nil)
        let stage = root.appendingPathComponent("stage")
        try archive.stageExport(to: stage)
        #expect(try ClipboardArchive(root: stage).snapshot(.init()).total == 0)
        #expect(try archive.snapshot(.init()).total == 1)
    }

    private func entry(_ text: String) -> ClipboardEntry {
        ClipboardEntry(
            id: text, sha256: String(repeating: "a", count: 64), types: ["public.utf8-plain-text"],
            ext: "txt", sourceApp: nil, sourceBundleID: nil, size: text.utf8.count, preview: text)
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentError(.failed, "The clipboard view fixture timed out.")
    }
}
