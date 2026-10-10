import Foundation
import Testing
import EdithExtensionSupport
@testable import ClipboardExtension

@Suite(.serialized) @MainActor struct ClipboardWorkerOwnershipTests {
    @Test func workerStopsStorageHistoryPaletteAndRequestsWithoutCapturing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "clipboard-worker-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let service = ClipboardService(archive: .init(root: root), defaults: defaults, changed: {})
        let worker = ClipboardWorker(service: service, capturesPasteboard: false)
        #expect(worker.isStopped == false)
        let capture = ClipboardCapture(
            payload: .init(
                data: Data("mock clip".utf8), types: ["public.text"], ext: "txt",
                preview: "mock clip"), sourceApp: "Mock Notes", sourceBundleID: "example.mock")
        _ = try await worker.execute(
            ClipboardServiceOperation.capture, payload: ClipboardMessage.encode(capture))
        let snapshot = try ClipboardMessage.decode(
            ClipboardSnapshot.self,
            from: await worker.execute(
                ClipboardServiceOperation.snapshot,
                payload: ClipboardMessage.encode(ClipboardSnapshotRequest())))
        #expect(snapshot.entries.map(\.preview) == ["mock clip"])
        await worker.shutdown()
        #expect(worker.isStopped)
        #expect(worker.store.entries.isEmpty)
        #expect(worker.history.entries.isEmpty)
        #expect(await service.activeRequests == 0)
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(ClipboardServiceOperation.snapshot, payload: Data())
        }
        await worker.shutdown()
        let restarted = ClipboardWorker(
            service: ClipboardService(archive: .init(root: root), defaults: defaults, changed: {}),
            capturesPasteboard: false)
        let retained = try await restarted.client.snapshot()
        #expect(retained.entries.count == 1)
        await restarted.shutdown()
    }

    @Test func unknownCommandsCannotReachStorage() async throws {
        let worker = ClipboardWorker(capturesPasteboard: false)
        defer { worker.store.shutdown() }
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("filesystem.delete", payload: Data())
        }
        await worker.shutdown()
    }
}
