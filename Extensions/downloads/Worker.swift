import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor
final class DownloadsWorker {
    let queue: DownloadWorker
    let downloader: YoutubeDownloader
    private var startup: Task<Void, Never>?
    private(set) var stopped = false

    init(queue: DownloadWorker? = nil, start: Bool = true) {
        let fixture = ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] != nil
        self.queue =
            queue
            ?? DownloadWorker(
                executable: { fixture ? nil : CLIToolEnvironment.executable(named: "yt-dlp") },
                galleryExecutable: {
                    fixture ? nil : CLIToolEnvironment.executable(named: "gallery-dl")
                },
                completed: {
                    guard !fixture,
                        let namespace = ExtensionEnvironment.values[
                            "EDITH_APPLICATION_IDENTIFIER"]
                    else { return }
                    DistributedNotificationCenter.default().postNotificationName(
                        Notification.Name(namespace + ".musicFolderChanged"), object: nil,
                        userInfo: nil, deliverImmediately: true)
                })
        downloader = YoutubeDownloader(client: DownloadsClient(worker: self.queue), start: start)
        let model = downloader
        DownloadsTools.shared.didChange = { [weak model] in model?.checkAvailability() }
        if start {
            let queue = self.queue
            startup = Task { try? await queue.start() }
        }
    }
    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped, payload.count <= 131_072 else { throw ExtensionPeerError.unavailable }
        await startup?.value
        try Task.checkCancellation()
        switch command {
        case "downloads.snapshot":
            guard payload.isEmpty || payload == Data("{}".utf8) else {
                throw ExtensionPeerError.invalidRequest
            }
            return try JSONEncoder().encode(await queue.snapshot())
        case "downloads.mutate":
            let mutation = try JSONDecoder().decode(DownloadsMutation.self, from: payload)
            return try JSONEncoder().encode(await queue.mutate(mutation))
        case "downloads.estimate":
            let url = try JSONDecoder().decode(URL.self, from: payload)
            return try JSONEncoder().encode(await queue.estimate(url))
        case "downloads.open", "downloads.reveal":
            let id = try JSONDecoder().decode(UUID.self, from: payload)
            let records = await queue.snapshot().records
            guard let record = records.first(where: { $0.id == id }), record.isFinished,
                case .done = record.status
            else { throw ExtensionPeerError.invalidRequest }
            if command == "downloads.open" {
                _ = try DownloadOperationExecution.open(id: id, file: queue.historyFile)
            } else {
                _ = try DownloadOperationExecution.reveal(id: id, file: queue.historyFile)
            }
            return Data()
        default: throw ExtensionPeerError.invalidRequest
        }
    }
    func cancelPendingWork() async {
        stopped = true
        startup?.cancel()
        downloader.cancelPendingWork()
        await queue.cancelPendingWork()
    }
    private var drainTask: Task<Void, Never>?
    func drain() async {
        await cancelPendingWork()
        if let drainTask { await drainTask.value; return }
        let startup = startup
        let downloader = downloader
        let queue = queue
        let task = Task { [startup, downloader, queue] in
            await startup?.value
            await downloader.drain()
            await DownloadsTools.shared.shutdown()
            await queue.cancelPendingWorkAndWait()
        }
        drainTask = task
        await task.value
    }
    private var shutdownTask: Task<Void, Never>?
    func shutdown() async {
        await cancelPendingWork()
        if let shutdownTask { await shutdownTask.value; return }
        let task = Task { await finishShutdown() }
        shutdownTask = task
        await task.value
    }
    private func finishShutdown() async {
        await drain()
        startup = nil
        await downloader.shutdown()
        await queue.stop()
    }
}
