import CryptoKit
import EdithExtensionSupport
import Foundation

@MainActor
final class DownloadsSurface {
    private let worker: DownloadsWorker
    private let privacyValues: @MainActor () -> [String: String]
    init(
        worker: DownloadsWorker,
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) {
        self.worker = worker
        self.privacyValues = privacyValues
    }
    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !worker.stopped else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "downloads", command: command, payload: payload,
            snapshot: { [self] tile in try await snapshot(tile) },
            perform: { [self] action in try await perform(action) }, privacyValues: privacyValues)
    }
    func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        let state = await worker.queue.snapshot()
        let records = state.records.filter {
            tile.sourceIDs?.contains(($0.kind ?? .audio).rawValue) ?? true
        }
        let status = DownloadQueueSnapshot(records: records)
        let rows = records.prefix(100).map { item in
            var actions: [SurfaceAction] = []
            if item.canRetry {
                actions.append(.init(Self.action("retry", item.id), "Retry", "arrow.clockwise"))
            }
            if !item.isFinished {
                actions.append(.init(Self.action("cancel", item.id), "Cancel", "stop.fill"))
            }
            if case .done = item.status {
                actions.append(.init(Self.action("reveal", item.id), "Show in Finder", "folder"))
            }
            if item.isFinished {
                actions.append(
                    .init(Self.action("remove", item.id), "Remove from history", "trash"))
            }
            return SurfaceDataRow(
                item.id.uuidString, sourceID: (item.kind ?? .audio).rawValue,
                title: String(
                    YoutubeDownloader.DownloadItem(record: item).resolvedTitle?.prefix(300)
                        ?? item.url.lastPathComponent.prefix(300)),
                detail: tile.shows("url") ? String((item.url.host ?? "").prefix(256)) : "",
                value: String(item.state.prefix(80)),
                icon: item.kind == .audio ? "music.note" : "arrow.down.circle",
                progress: Self.progress(item.status), field: "queue", actions: actions)
        }
        return SurfaceSnapshot(
            providerID: "downloads",
            metrics: [
                .init("queued", "Queued", String(status.queued)),
                .init("running", "Running", String(status.resolving + status.downloading)),
                .init("finished", "Finished", String(status.done)),
                .init("failed", "Retry available", String(status.failed + status.interrupted)),
            ], rows: rows,
            sources: DownloadKind.allCases.map { .init($0.rawValue, $0.title) },
            message: state.problem
                ?? (state.executable == nil
                    ? "Install download tools in Downloads settings to start queued jobs." : nil),
            updatedAt: state.readAt)
    }
    private func perform(_ action: String) async throws {
        let state = await worker.queue.snapshot()
        for record in state.records {
            if action == Self.action("retry", record.id), record.canRetry {
                _ = try await worker.queue.mutate(.retry(id: record.id, all: false)); return
            }
            if action == Self.action("cancel", record.id), !record.isFinished {
                _ = try await worker.queue.mutate(
                    .cancel(id: record.id, includeQueued: true, reason: "Cancelled"));
                return
            }
            if action == Self.action("remove", record.id), record.isFinished {
                _ = try await worker.queue.mutate(.remove(id: record.id)); return
            }
            if action == Self.action("reveal", record.id), case .done = record.status {
                _ = try DownloadOperationExecution.reveal(id: record.id); return
            }
        }
        throw ExtensionPeerError.invalidRequest
    }
    static func action(_ verb: String, _ id: UUID) -> String {
        SHA256.hash(data: Data((verb + ":" + id.uuidString).utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
    static func progress(_ status: DownloadStatus) -> Double? {
        guard case .downloading(let value, _, _) = status,
            let percent = Double(value.replacingOccurrences(of: "%", with: "")), percent.isFinite
        else { return nil }
        return max(0, min(1, percent / 100))
    }
}
