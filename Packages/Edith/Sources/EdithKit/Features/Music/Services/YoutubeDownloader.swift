import AppKit
import Foundation
import Observation

extension Notification.Name {
    public static let musicFolderChangedLocally = Notification.Name("musicFolderChanged")
}

public enum DownloadStatus: Equatable, Codable, Sendable {
    case queued
    case resolving
    case downloading(progress: String, videoIndex: Int, videoCount: Int)
    case done(String)
    case error(String)
    case interrupted(String?)

    enum CodingKeys: String, CodingKey {
        case kind, value, a, b, c
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "queued": self = .queued
        case "resolving": self = .resolving
        case "downloading":
            let p = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
            let vi = try c.decodeIfPresent(Int.self, forKey: .a) ?? 0
            let vc = try c.decodeIfPresent(Int.self, forKey: .b) ?? 0
            self = .downloading(progress: p, videoIndex: vi, videoCount: vc)
        case "done":
            self = .done(try c.decode(String.self, forKey: .value))
        case "error":
            self = .error(try c.decode(String.self, forKey: .value))
        case "interrupted":
            self = .interrupted(try c.decodeIfPresent(String.self, forKey: .value))
        default: self = .interrupted(nil)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued: try c.encode("queued", forKey: .kind)
        case .resolving: try c.encode("resolving", forKey: .kind)
        case let .downloading(p, vi, vc):
            try c.encode("downloading", forKey: .kind)
            try c.encode(p, forKey: .value)
            try c.encode(vi, forKey: .a)
            try c.encode(vc, forKey: .b)
        case let .done(o):
            try c.encode("done", forKey: .kind)
            try c.encode(o, forKey: .value)
        case let .error(e):
            try c.encode("error", forKey: .kind)
            try c.encode(e, forKey: .value)
        case let .interrupted(r):
            try c.encode("interrupted", forKey: .kind)
            try c.encodeIfPresent(r, forKey: .value)
        }
    }
}

public enum DownloadKind: String, Codable, Sendable, CaseIterable {
    case audio
    case video

    public var title: String {
        switch self {
        case .audio: "Audio"
        case .video: "Video"
        }
    }

    public var fileExtension: String {
        switch self {
        case .audio: "m4a"
        case .video: "mp4"
        }
    }
}

public struct DownloadEstimate: Codable, Equatable, Sendable {
    public let audioBytes: Int64?
    public let videoBytes: Int64?
    public let approximate: Bool

    public init(audioBytes: Int64?, videoBytes: Int64?, approximate: Bool) {
        self.audioBytes = audioBytes
        self.videoBytes = videoBytes
        self.approximate = approximate
    }

    public func bytes(for kind: DownloadKind) -> Int64? {
        switch kind {
        case .audio: audioBytes
        case .video: videoBytes
        }
    }

    public static func + (lhs: DownloadEstimate, rhs: DownloadEstimate) -> DownloadEstimate {
        DownloadEstimate(
            audioBytes: sum(lhs.audioBytes, rhs.audioBytes),
            videoBytes: sum(lhs.videoBytes, rhs.videoBytes),
            approximate: lhs.approximate || rhs.approximate)
    }

    private static func sum(_ a: Int64?, _ b: Int64?) -> Int64? {
        guard let a else { return b }
        guard let b else { return a }
        return a + b
    }
}

public enum DownloadSizeParser {
    public static func estimate(fromJSON data: Data) -> DownloadEstimate? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let formats = root["formats"] as? [[String: Any]]
        else { return nil }
        var missing = false
        let audio = best(of: formats.filter { isAudioOnly($0) }, by: "abr")
        let video = best(of: formats.filter { isVideoOnly($0) }, by: "height")
        let combined = best(of: formats.filter { isCombined($0) }, by: "height")

        let audioBytes = size(of: audio, missing: &missing)
        var videoBytes = size(of: video, missing: &missing)
        if let bytes = videoBytes, let audioBytes {
            videoBytes = bytes + audioBytes
        } else if videoBytes == nil {
            videoBytes = size(of: combined, missing: &missing)
        }
        guard audioBytes != nil || videoBytes != nil else { return nil }
        return DownloadEstimate(
            audioBytes: audioBytes, videoBytes: videoBytes, approximate: true)
    }

    private static func isAudioOnly(_ format: [String: Any]) -> Bool {
        codec(format, "vcodec") == "none" && codec(format, "acodec") != "none"
    }

    private static func isVideoOnly(_ format: [String: Any]) -> Bool {
        codec(format, "acodec") == "none" && codec(format, "vcodec") != "none"
    }

    private static func isCombined(_ format: [String: Any]) -> Bool {
        codec(format, "acodec") != "none" && codec(format, "vcodec") != "none"
    }

    private static func codec(_ format: [String: Any], _ key: String) -> String {
        (format[key] as? String) ?? "none"
    }

    private static func best(of formats: [[String: Any]], by key: String) -> [String: Any]? {
        formats.max { rank($0, key) < rank($1, key) }
    }

    private static func rank(_ format: [String: Any], _ key: String) -> Double {
        (format[key] as? Double) ?? Double(format[key] as? Int ?? 0)
    }

    private static func size(of format: [String: Any]?, missing: inout Bool) -> Int64? {
        guard let format else { return nil }
        for key in ["filesize", "filesize_approx"] {
            if let value = format[key] as? Int64 { return value }
            if let value = format[key] as? Int { return Int64(value) }
            if let value = format[key] as? Double { return Int64(value) }
        }
        missing = true
        return nil
    }
}

@MainActor
@Observable
public final class YoutubeDownloader {
    public static let shared = YoutubeDownloader()

    public private(set) var items: [DownloadItem] = []
    public private(set) var isRunning = false
    public private(set) var unavailableReason: String?
    public private(set) var ytdlpVersion: String?
    public private(set) var isUpdatingYTDLP = false
    public private(set) var ytdlpUpdateMessage: String?
    public private(set) var updateResult: Result<String, Error>? = nil
    public private(set) var estimates: [URL: DownloadEstimate] = [:]

    public var errorMessage: String?
    @ObservationIgnored private let client: AgentDownloadClient
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var availabilityTask: Task<Void, Never>?
    @ObservationIgnored private var provisioningObserver: NSObjectProtocol?
    @ObservationIgnored private var activeGeneration: UUID?
    @ObservationIgnored private var revision = -1
    @ObservationIgnored private var availabilityGeneration = UUID()
    @ObservationIgnored private var downloadsEnabled = false
    @ObservationIgnored private let observesAgent: Bool

    public struct DownloadItem: Identifiable, Equatable {
        public let id: UUID
        public let url: URL
        public var status: DownloadStatus
        public var outputFilename: String?
        public let createdAt: Date
        public var kind: DownloadKind = .audio
        public var logs: String = ""
        public var resultPaths: [String]?

        public init(record: DownloadRecord, logs: String = "") {
            id = record.id
            url = record.url
            status = record.status
            outputFilename = record.outputFilename
            createdAt = record.createdAt
            kind = record.kind ?? .audio
            self.logs = logs
            resultPaths = record.resultPaths
        }

        public var record: DownloadRecord {
            DownloadRecord(
                id: id, url: url, status: status, outputFilename: outputFilename,
                createdAt: createdAt, kind: kind, resultPaths: resultPaths)
        }

        public static func == (lhs: DownloadItem, rhs: DownloadItem) -> Bool {
            lhs.id == rhs.id
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

        public var thumbnailURL: URL? { YoutubeDownloader.thumbnailURL(for: url) }
    }

    nonisolated public static func videoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host.contains("youtu.be") {
            let id = url.lastPathComponent
            return id.isEmpty || id == "/" ? nil : id
        }
        guard host.contains("youtube.com") else { return nil }
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

    init(client: AgentDownloadClient = AgentDownloadClient(), start: Bool = true) {
        self.client = client
        observesAgent = start
        guard start else { return }
        checkAvailability()
        streamTask = Task { [weak self, client] in
            if let snapshot = try? await client.snapshot() { self?.apply(snapshot) }
            for await snapshot in AgentTopicStream.values(
                DownloadWorkerSnapshot.self, topic: .downloads, client: client.client)
            {
                guard !Task.isCancelled else { return }
                self?.apply(snapshot)
            }
        }
        provisioningObserver = NotificationCenter.default.addObserver(
            forName: .cliToolProvisioned, object: nil, queue: .main
        ) { [weak self] notification in
            guard notification.userInfo?["toolID"] as? String == CLIToolSpec.youtubeDownloader.id
            else { return }
            Task { @MainActor in self?.checkAvailability() }
        }
    }

    func apply(_ snapshot: DownloadWorkerSnapshot) {
        let generationChanged = activeGeneration != snapshot.generation
        if generationChanged {
            activeGeneration = snapshot.generation
            revision = -1
        }
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision
        items = snapshot.records.map {
            DownloadItem(record: $0, logs: snapshot.logs[$0.id.uuidString] ?? "")
        }
        isRunning = snapshot.running > 0
        downloadsEnabled = snapshot.enabled
        if let problem = snapshot.problem {
            unavailableReason = problem
        } else if !snapshot.enabled {
            unavailableReason =
                "Downloads are disabled. Enable the Downloads extension to continue."
        } else if snapshot.executable == nil {
            unavailableReason =
                "yt-dlp is not installed. Open Music extension settings to install it."
        } else if ytdlpVersion != nil {
            unavailableReason = nil
        }
        if observesAgent, generationChanged, availabilityTask == nil { checkAvailability() }
    }

    public func checkAvailability() {
        availabilityTask?.cancel()
        let generation = UUID()
        availabilityGeneration = generation
        availabilityTask = Task {
            defer { if generation == availabilityGeneration { availabilityTask = nil } }
            do {
                let snapshot = try await client.snapshot()
                try Task.checkCancellation()
                apply(snapshot)
                guard snapshot.enabled, snapshot.problem == nil else { return }
                let status = await DownloadToolOperationExecution.status(
                    executable: snapshot.executable)
                try Task.checkCancellation()
                guard downloadsEnabled else { return }
                unavailableReason =
                    status.installed
                    ? nil : "yt-dlp is not installed. Open Music extension settings to install it."
                ytdlpVersion = status.version
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                unavailableReason = error.localizedDescription
            }
        }
    }

    private func mutate(_ request: AgentDownloadMutation) {
        errorMessage = nil
        Task {
            do {
                _ = try await client.mutateAsync(request)
                apply(try await client.snapshot())
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func updateYTDLP(completion: ((Result<String, Error>) -> Void)? = nil) {
        isUpdatingYTDLP = true
        updateResult = nil
        ytdlpUpdateMessage = nil
        Task {
            do {
                let update = try await DownloadToolOperationExecution.update(
                    executable: CLIToolEnvironment.executable(named: "yt-dlp"))
                let text = update.output.isEmpty ? "yt-dlp updated" : update.output
                updateResult = .success(text)
                ytdlpUpdateMessage = text
                ytdlpVersion = update.after
                unavailableReason = nil
            } catch {
                updateResult = .failure(error)
                ytdlpUpdateMessage = error.localizedDescription
            }
            isUpdatingYTDLP = false
            completion?(updateResult!)
        }
    }

    nonisolated public static func parseURLs(from text: String) -> [URL] {
        text
            .components(separatedBy: CharacterSet([",", "\n", "\r"]))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
            .filter { isYouTubeURL($0) }
    }

    nonisolated private static func isYouTubeURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("youtube.com") || host.contains("youtu.be")
    }

    public func enqueue(urls: [URL], prefix: String, kind: DownloadKind = .audio) {
        mutate(.enqueue(urls: urls, prefix: prefix, kind: kind, outputDirectory: Repo.musicDir))
    }

    public func estimate(for url: URL) async -> DownloadEstimate? {
        if let cached = estimates[url] { return cached }
        do {
            let value = try await client.estimate(url)
            if let value {
                if estimates.count >= 100 { estimates.removeAll(keepingCapacity: true) }
                estimates[url] = value
            }
            return value
        } catch {
            return nil
        }
    }

    public func sourceURL(forFileNamed name: String) -> URL? {
        for item in items {
            guard case let .done(output) = item.status else { continue }
            if output.components(separatedBy: ", ").contains(name) { return item.url }
        }
        return nil
    }

    public func retry(_ item: DownloadItem) { mutate(.retry(id: item.id, all: false)) }
    public func retryAll() { mutate(.retry(id: nil, all: true)) }
    public func clearHistory() { mutate(.clear(includeActive: true)) }
    public func remove(_ item: DownloadItem) { mutate(.remove(id: item.id)) }
    public func cancel(_ item: DownloadItem) {
        mutate(.cancel(id: item.id, includeQueued: true, reason: "Cancelled"))
    }

    @discardableResult
    public func openResult(_ item: DownloadItem) -> Bool {
        (try? DownloadOperationExecution.open(id: item.id)) != nil
    }

    @discardableResult
    public func revealResult(_ item: DownloadItem) -> Bool {
        (try? DownloadOperationExecution.reveal(id: item.id)) != nil
    }

    nonisolated static let intermediateExtensions: Set<String> =
        ["webm", "mkv", "opus", "ogg", "part", "ytdl", "temp"]

    nonisolated public static func cleanupIntermediates(for producedPaths: [String]) {
        let fm = FileManager.default
        for path in producedPaths {
            let produced = URL(fileURLWithPath: path)
            let stem = produced.deletingPathExtension().lastPathComponent
            let directory = produced.deletingLastPathComponent()
            let siblings =
                (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for sibling in siblings
            where sibling != produced
                && sibling.deletingPathExtension().lastPathComponent == stem
                && intermediateExtensions.contains(sibling.pathExtension.lowercased())
            {
                try? fm.removeItem(at: sibling)
            }
        }
    }

    public func cancelAll() { mutate(.cancel(id: nil, includeQueued: true, reason: "Cancelled")) }

    deinit {
        streamTask?.cancel()
        availabilityTask?.cancel()
        if let provisioningObserver {
            NotificationCenter.default.removeObserver(provisioningObserver)
        }
    }

    nonisolated public static func parseProgress(from text: String) -> (
        progress: String, videoIndex: Int, videoCount: Int
    ) {
        if let range = text.range(
            of: #"Downloading video (\d+) of (\d+)"#, options: .regularExpression)
        {
            let match = String(text[range])
            let nums = match.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap(Int.init)
            if nums.count >= 2 {
                let vi = nums.suffix(2)
                return ("...", vi.first ?? 1, vi.last ?? 1)
            }
        }

        if let range = text.range(of: #"(\d+\.\d+)%\s*of"#, options: .regularExpression) {
            let match = String(text[range])
            if let pct = match.components(separatedBy: "%").first?.trimmingCharacters(
                in: .whitespaces
            )
            .components(separatedBy: " ").last {
                return ("\(pct)%", 0, 0)
            }
        }

        if let range = text.range(of: #"\[download\]\s+(\d+\.\d+)%"#, options: .regularExpression) {
            let match = String(text[range])
            let pct = match.components(separatedBy: CharacterSet.whitespaces).compactMap {
                s -> String? in
                let t = s.trimmingCharacters(in: .whitespaces)
                return t.hasSuffix("%") ? t : nil
            }.first
            if let pct {
                return (pct, 0, 0)
            }
        }

        if text.contains("[ExtractAudio]") { return ("Converting...", 0, 0) }
        if text.contains("[Metadata]") { return ("Metadata...", 0, 0) }
        if text.contains("[Merger]") { return ("Merging...", 0, 0) }
        return ("", 0, 0)
    }
}
