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
        let ordered = records.sorted {
            func priority(_ value: DownloadRecord) -> Int {
                if value.canRetry { return 3 }
                if !value.isFinished { return 2 }
                return 1
            }
            return priority($0) == priority($1)
                ? $0.createdAt > $1.createdAt : priority($0) > priority($1)
        }
        let running = records.filter { !$0.isFinished && $0.status != .queued }.count
        let rows = ordered.prefix(100).map { item in
            var actions: [SurfaceAction] = []
            if item.canRetry {
                actions.append(.init(Self.action("retry", item.id), "Retry", "arrow.clockwise"))
            }
            if !item.isFinished {
                actions.append(.init(Self.action("cancel", item.id), "Cancel", "xmark"))
            }
            if case .done = item.status {
                actions.append(.init(Self.action("reveal", item.id), "Show file", "folder"))
            }
            return SurfaceDataRow(
                item.id.uuidString, sourceID: (item.kind ?? .audio).rawValue,
                title: Self.title(item),
                detail: tile.shows("url") ? String(item.detail.prefix(256)) : "",
                value: String(item.state.capitalized.prefix(80)),
                icon: "arrow.down.circle",
                progress: Self.progress(item.status), field: "queue", actions: actions)
        }
        return SurfaceSnapshot(
            providerID: "downloads",
            metrics: [
                .init("running", "Downloading", String(running)),
                .init("queued", "Queued", String(records.filter { $0.status == .queued }.count)),
                .init("failed", "Needs retry", String(records.filter(\.canRetry).count)),
                .init(
                    "finished", "Completed",
                    String(
                        records.filter { if case .done = $0.status { true } else { false } }.count)),
            ], rows: rows,
            sources: DownloadKind.allCases.map { .init($0.rawValue, $0.rawValue.capitalized) },
            message: state.problem
                ?? (records.isEmpty ? "No downloads in this selection." : nil),
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
    static func title(_ record: DownloadRecord) -> String {
        let filename = record.url.lastPathComponent
        let fallback =
            filename.isEmpty || filename == "/" ? (record.url.host ?? "Download") : filename
        return String(
            (YoutubeDownloader.DownloadItem(record: record).resolvedTitle ?? fallback).prefix(300))
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
