import EdithExtensionSupport
import Foundation
import Testing

@testable import DownloadsExtension

extension DownloadsExtensionTests {
    @MainActor @Suite(.serialized) struct SurfaceTests {
        @Test func selectedSourcesAndFieldsPreserveOnlyVisibleQueueControls() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "downloads-surface-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("queue.json")
            let audio = DownloadRecord(
                url: URL(string: "https://example.test/audio")!, status: .error("Retry available"),
                outputFilename: nil, createdAt: Date(), kind: .audio)
            let video = DownloadRecord(
                url: URL(string: "https://example.test/video")!, status: .queued,
                outputFilename: nil, createdAt: Date(), kind: .video)
            try DownloadQueue.save([audio, video], to: file)
            let queue = DownloadWorker(file: file, executable: { nil })
            let worker = DownloadsWorker(queue: queue, start: false)
            let surface = DownloadsSurface(worker: worker)
            var tile = SurfaceTile(.ability("downloads"))
            tile.sourceIDs = ["audio"]
            tile.hiddenFields = ["url"]
            let snapshot = try await read(surface, tile)
            #expect(snapshot.rows.count == 1)
            #expect(snapshot.rows.first?.id == audio.id.uuidString)
            #expect(snapshot.rows.first?.detail == "")
            #expect(snapshot.rows.first?.actions.map(\.title).contains("Retry") == true)
            #expect(snapshot.metrics.first(where: { $0.id == "queued" })?.value == "0")
            let hiddenCancel = SurfaceActionRequest(
                snapshot: .init(target: .notch, tile: tile),
                actionID: DownloadsSurface.action("cancel", video.id))
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await surface.execute(
                    "surface.perform", payload: hiddenCancel.encoded(providerID: "downloads"))
            }
            #expect(
                await queue.snapshot().records.first(where: { $0.id == video.id })?.status
                    == .queued)
            await worker.shutdown()
        }
        @Test func currentOpaqueActionCannotBeReplayedAfterItsStateChanges() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "downloads-action-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("queue.json")
            let record = DownloadRecord(
                url: URL(string: "https://example.test/video")!, status: .error("Retry"),
                outputFilename: nil, createdAt: Date(), kind: .video)
            try DownloadQueue.save([record], to: file)
            let queue = DownloadWorker(file: file, executable: { nil })
            let worker = DownloadsWorker(queue: queue, start: false)
            let surface = DownloadsSurface(worker: worker)
            let tile = SurfaceTile(.media)
            let action = SurfaceActionRequest(
                snapshot: .init(target: .home, tile: tile),
                actionID: DownloadsSurface.action("retry", record.id))
            _ = try await surface.execute(
                "surface.perform", payload: action.encoded(providerID: "downloads"))
            #expect(await queue.snapshot().records.first?.status == .queued)
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await surface.execute(
                    "surface.perform", payload: action.encoded(providerID: "downloads"))
            }
            await worker.shutdown()
        }
        @Test func presentingSuppressesQueueAndRejectsAllActions() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "downloads-privacy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let queue = DownloadWorker(
                file: root.appendingPathComponent("queue.json"), executable: { nil })
            let worker = DownloadsWorker(queue: queue, start: false)
            let surface = DownloadsSurface(
                worker: worker, privacyValues: { ["active": "1", "blurStudio": "1"] })
            let tile = SurfaceTile(.ability("downloads"))
            let snapshot = try await read(surface, tile)
            #expect(snapshot.rows.isEmpty && snapshot.metrics.isEmpty && snapshot.actions.isEmpty)
            #expect(snapshot.message == "Hidden while presenting.")
            await worker.shutdown()
            await #expect(throws: ExtensionPeerError.self) { _ = try await read(surface, tile) }
        }
        @Test func rootMediaURLsKeepAValidBoundedDisplayTitle() {
            let record = DownloadRecord(
                url: URL(string: "https://example.test/")!, status: .queued, outputFilename: nil,
                createdAt: Date(), kind: .video)
            #expect(DownloadsSurface.title(record) == "example.test")
        }
        @Test func malformedPercentNeverLeaksAnUnboundedChartValue() {
            #expect(
                DownloadsSurface.progress(
                    .downloading(progress: "nan%", videoIndex: 0, videoCount: 1)) == nil)
            #expect(
                DownloadsSurface.progress(
                    .downloading(progress: "200%", videoIndex: 0, videoCount: 1)) == 1)
            #expect(
                DownloadsSurface.progress(
                    .downloading(progress: "-20%", videoIndex: 0, videoCount: 1)) == 0)
        }
        private func read(_ surface: DownloadsSurface, _ tile: SurfaceTile) async throws
            -> SurfaceSnapshot
        {
            try SurfaceSnapshot.decode(
                try await surface.execute(
                    "surface.snapshot",
                    payload: SurfaceSnapshotRequest(target: .home, tile: tile).encoded(
                        providerID: "downloads")), providerID: "downloads")
        }
    }
}
