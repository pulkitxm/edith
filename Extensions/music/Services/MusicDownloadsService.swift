import AppKit
import EdithExtensionSupport
import Foundation

@MainActor final class MusicDownloadsService {
    private let worker: MusicWorker
    private let queue: DownloadWorker
    private let downloader: YoutubeDownloader
    private var stopped = false
    private var panel: NSOpenPanel?

    init(worker: MusicWorker, queue: DownloadWorker = .shared, downloader: YoutubeDownloader? = nil)
    {
        self.worker = worker; self.queue = queue; self.downloader = downloader ?? .shared
    }

    func execute(_ operation: String, payload: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        switch operation {
        case "music.ui.downloads.read":
            let snapshot = await queue.snapshot()
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            var failure: String?
            if case let .failure(error) = downloader.updateResult {
                failure = error.localizedDescription
            }
            return try JSONEncoder().encode(
                MusicDownloadsState(
                    snapshot: snapshot, unavailableReason: downloader.unavailableReason,
                    updating: downloader.isUpdatingYTDLP,
                    updateMessage: downloader.ytdlpUpdateMessage,
                    updateError: failure,
                    directories: Dictionary(
                        uniqueKeysWithValues: DownloadKind.allCases.map {
                            ($0.rawValue, MediaDownloadInput.defaultDirectory(for: $0))
                        })))
        case "music.ui.downloads.action":
            let action = try JSONDecoder().decode(MusicDownloadAction.self, from: payload)
            guard action.urls.count <= 128, action.urls.allSatisfy(MediaDownloadInput.isValid),
                action.prefix.utf8.count <= 256, !action.prefix.contains("/"),
                !action.prefix.contains("\\"),
                action.outputDirectory == nil || action.outputDirectory!.isFileURL
            else { throw ExtensionPeerError.invalidRequest }
            switch action.kind {
            case .enqueue:
                guard !action.urls.isEmpty else { throw ExtensionPeerError.invalidRequest }
                _ = try await queue.mutate(
                    .enqueue(
                        urls: action.urls, prefix: action.prefix,
                        kind: action.downloadKind,
                        outputDirectory: action.outputDirectory
                            ?? MediaDownloadInput.defaultDirectory(for: action.downloadKind),
                        browser: action.browser))
            case .retry:
                guard let id = action.id else { throw ExtensionPeerError.invalidRequest }
                _ = try await queue.mutate(.retry(id: id, all: false))
            case .retryAll: _ = try await queue.mutate(.retry(id: nil, all: true))
            case .clearHistory: _ = try await queue.mutate(.clear(includeActive: false))
            case .remove:
                guard let id = action.id else { throw ExtensionPeerError.invalidRequest }
                _ = try await queue.mutate(.remove(id: id))
            case .cancel:
                guard let id = action.id else { throw ExtensionPeerError.invalidRequest }
                _ = try await queue.mutate(
                    .cancel(id: id, includeQueued: true, reason: "Cancelled"))
            case .cancelAll:
                _ = try await queue.mutate(
                    .cancel(id: nil, includeQueued: true, reason: "Cancelled"))
            case .checkAvailability: downloader.checkAvailability()
            case .updateTools: downloader.updateYTDLP()
            case .open, .reveal:
                guard let id = action.id else { throw ExtensionPeerError.invalidRequest }
                if action.kind == .open {
                    _ = try DownloadOperationExecution.open(id: id)
                } else {
                    _ = try DownloadOperationExecution.reveal(id: id)
                }
            }
            return Data("{}".utf8)
        case "music.ui.downloads.estimate":
            let url = try JSONDecoder().decode(URL.self, from: payload)
            guard MediaDownloadInput.isValid(url) else { throw ExtensionPeerError.invalidRequest }
            let value = try await queue.estimate(url)
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            return try JSONEncoder().encode(value)
        case "music.ui.downloads.paste":
            let value = NSPasteboard.general.string(forType: .string).map {
                String($0.prefix(131_072))
            }
            return try JSONEncoder().encode(value)
        case "music.ui.downloads.chooseDirectory":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
            panel.directoryURL = MusicStorage.musicDir
            self.panel = panel
            defer { self.panel = nil }
            let response = await withTaskCancellationHandler {
                await panel.begin()
            } onCancel: {
                Task { @MainActor in panel.cancel(nil) }
            }
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            return try JSONEncoder().encode(response == .OK ? panel.url : nil)
        case "music.ui.downloads.thumbnail":
            let url = try JSONDecoder().decode(URL.self, from: payload)
            let snapshot = await queue.snapshot()
            guard snapshot.records.contains(where: { $0.url == url }),
                let thumbnail = MediaDownloadInput.isDirectImage(url)
                    ? url : YoutubeDownloader.thumbnailURL(for: url)
            else { throw ExtensionPeerError.invalidRequest }
            let image = try await worker.streamingThumbnail(thumbnail)
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            return try JSONEncoder().encode(image?.data ?? Data())
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    func stop() { stopped = true; panel?.cancel(nil); panel = nil }
}
