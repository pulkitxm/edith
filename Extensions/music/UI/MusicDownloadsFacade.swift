import Foundation
import Observation
import EdithExtensionSupport

@MainActor @Observable final class EmbeddedYoutubeDownloader {
    static let shared = EmbeddedYoutubeDownloader()
    private(set) var items: [DownloadItem] = []
    private(set) var isRunning = false
    private(set) var unavailableReason: String?
    private(set) var isUpdatingYTDLP = false
    private(set) var ytdlpUpdateMessage: String?
    private(set) var updateResult: Result<String, Error>?
    private(set) var directories: [String: URL] = [:]
    var errorMessage: String?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lifecycle = 0
    @ObservationIgnored private var revision = -1
    @ObservationIgnored private var generation: UUID?

    public struct DownloadItem: Identifiable, Equatable {
        public let id: UUID
        public let url: URL
        public var status: EmbeddedDownloadStatus
        public var outputFilename: String?
        public let createdAt: Date
        public var kind: EmbeddedDownloadKind = .audio
        public var logs: String = ""
        public var resultPaths: [String]?
        public var browser: EmbeddedDownloadBrowser?

        public init(record: EmbeddedDownloadRecord, logs: String = "") {
            id = record.id
            url = record.url
            status = record.status
            outputFilename = record.outputFilename
            createdAt = record.createdAt
            kind = record.kind ?? .audio
            self.logs = logs
            resultPaths = record.resultPaths
            browser = record.browser
        }

        public var record: EmbeddedDownloadRecord {
            EmbeddedDownloadRecord(
                id: id, url: url, status: status, outputFilename: outputFilename,
                createdAt: createdAt, kind: kind, resultPaths: resultPaths, browser: browser)
        }

        public var resolvedTitle: String? {
            if case let .done(output) = status {
                let first = output.components(separatedBy: ", ").first ?? output
                let stem = (first as NSString).deletingPathExtension
                return stem.isEmpty ? nil : stem
            }
            for line in logs.components(separatedBy: .newlines).reversed() {
                guard let range = line.range(of: "Destination: ") else { continue }
                let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                if !stem.isEmpty { return stem }
            }
            return nil
        }

        public var thumbnailURL: URL? { EmbeddedYoutubeDownloader.thumbnailURL(for: url) }
    }

    nonisolated public static func videoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            let id = url.lastPathComponent
            return id.isEmpty || id == "/" ? nil : id
        }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty
        {
            return v
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        if let idx = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" }),
            idx + 1 < parts.count
        {
            return parts[idx + 1]
        }
        return nil
    }

    nonisolated public static func thumbnailURL(for url: URL) -> URL? {
        guard let id = videoID(from: url) else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(id)/mqdefault.jpg")
    }

    nonisolated public static func parseURLs(from text: String) -> [URL] {
        var seen = Set<URL>()
        return
            text
            .replacingOccurrences(
                of: #",(?=\s*(?:https?://|,|$))"#, with: "\n", options: .regularExpression
            )
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
            .filter { EmbeddedMediaDownloadInput.isValid($0) && seen.insert($0).inserted }
    }

    func apply(_ state: EmbeddedMusicDownloadsState) throws {
        let snapshot = state.snapshot
        guard snapshot.records.count <= 10_000, snapshot.logs.count <= 10_000,
            snapshot.revision >= 0,
            snapshot.records.allSatisfy({ EmbeddedMediaDownloadInput.isValid($0.url) }),
            snapshot.logs.values.allSatisfy({ $0.utf8.count <= 64_000 }),
            state.directories.values.allSatisfy({ $0.isFileURL })
        else { throw ExtensionPeerError.invalidRequest }
        if generation == snapshot.generation, snapshot.revision < revision { return }
        generation = snapshot.generation; revision = snapshot.revision
        items = snapshot.records.map {
            DownloadItem(record: $0, logs: snapshot.logs[$0.id.uuidString] ?? "")
        }
        isRunning = snapshot.running > 0
        unavailableReason = state.unavailableReason ?? snapshot.problem
        isUpdatingYTDLP = state.updating; ytdlpUpdateMessage = state.updateMessage
        directories = state.directories
        if let error = state.updateError {
            updateResult = .failure(MusicDownloadUIError(message: error))
        } else if let message = state.updateMessage, !state.updating {
            updateResult = .success(message)
        }
    }

    func refresh() async {
        let token = lifecycle
        do {
            let data = try await EmbeddedMusicRemote.shared.dataRequest("music.ui.downloads.read")
            let state = try JSONDecoder().decode(EmbeddedMusicDownloadsState.self, from: data)
            try Task.checkCancellation()
            guard token == lifecycle else { return }
            try apply(state)
        } catch {
            if !Task.isCancelled, token == lifecycle { errorMessage = error.localizedDescription }
        }
    }

    func stop() {
        lifecycle += 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); items = []; directories = [:]; revision = -1; generation = nil
        isRunning = false; isUpdatingYTDLP = false; errorMessage = nil
        unavailableReason = nil; updateResult = nil; ytdlpUpdateMessage = nil
    }

    private func send(_ action: EmbeddedMusicDownloadAction) {
        let id = UUID(); let token = lifecycle
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[id] = nil }
            do {
                _ = try await EmbeddedMusicRemote.shared.dataRequest(
                    "music.ui.downloads.action", payload: JSONEncoder().encode(action))
                guard token == self.lifecycle else { return }
                await self.refresh()
            } catch {
                if !Task.isCancelled, token == self.lifecycle {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func checkAvailability() { send(.init(kind: .checkAvailability)) }
    func updateYTDLP() { send(.init(kind: .updateTools)) }
    func retry(_ item: DownloadItem) { send(.init(kind: .retry, id: item.id)) }
    func retryAll() { send(.init(kind: .retryAll)) }
    func clearHistory() { send(.init(kind: .clearHistory)) }
    func remove(_ item: DownloadItem) { send(.init(kind: .remove, id: item.id)) }
    func cancel(_ item: DownloadItem) { send(.init(kind: .cancel, id: item.id)) }
    func cancelAll() { send(.init(kind: .cancelAll)) }
    func openResult(_ item: DownloadItem) { send(.init(kind: .open, id: item.id)) }
    func revealResult(_ item: DownloadItem) { send(.init(kind: .reveal, id: item.id)) }
    func enqueue(
        urls: [URL], prefix: String, kind: EmbeddedDownloadKind = .audio,
        outputDirectory: URL? = nil, browser: EmbeddedDownloadBrowser? = nil
    ) {
        send(
            .init(
                kind: .enqueue, urls: urls, prefix: prefix, downloadKind: kind,
                outputDirectory: outputDirectory, browser: browser))
    }

    func estimate(for url: URL) async -> EmbeddedDownloadEstimate? {
        guard let payload = try? JSONEncoder().encode(url),
            let data = try? await EmbeddedMusicRemote.shared.dataRequest(
                "music.ui.downloads.estimate", payload: payload)
        else { return nil }
        return try? JSONDecoder().decode(EmbeddedDownloadEstimate?.self, from: data)
    }

    func paste() async -> String? {
        guard
            let data = try? await EmbeddedMusicRemote.shared.dataRequest("music.ui.downloads.paste")
        else { return nil }
        return try? JSONDecoder().decode(String?.self, from: data)
    }

    func chooseDirectory() async -> URL? {
        guard
            let data = try? await EmbeddedMusicRemote.shared.dataRequest(
                "music.ui.downloads.chooseDirectory")
        else { return nil }
        return try? JSONDecoder().decode(URL?.self, from: data)
    }
}

private struct MusicDownloadUIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
