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
        let fixture = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
        self.queue =
            queue
            ?? DownloadWorker(
                executable: { fixture ? nil : CLIToolEnvironment.executable(named: "yt-dlp") },
                galleryExecutable: {
                    fixture ? nil : CLIToolEnvironment.executable(named: "gallery-dl")
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
    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        startup?.cancel()
        await startup?.value
        startup = nil
        await downloader.shutdown()
        await DownloadsTools.shared.shutdown()
        await queue.stop()
    }
}
