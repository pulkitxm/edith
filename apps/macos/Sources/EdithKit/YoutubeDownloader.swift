import AppKit
import Foundation

extension Notification.Name {
    public static let musicFolderChanged = Notification.Name("musicFolderChanged")
}

public enum DownloadStatus: Equatable, Codable {
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

private struct SavedItem: Codable {
    let url: URL
    var status: DownloadStatus
    var outputFilename: String?
    var createdAt: Date
}

@MainActor
public final class YoutubeDownloader: ObservableObject {
    public static let shared = YoutubeDownloader()

    @Published public private(set) var items: [DownloadItem] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var unavailableReason: String?
    @Published public private(set) var ytdlpVersion: String?
    @Published public private(set) var isUpdatingYTDLP = false
    @Published public private(set) var ytdlpUpdateMessage: String?
    @Published public private(set) var updateResult: Result<String, Error>? = nil

    private var currentProcess: Process?
    private var currentItemID: UUID?
    private var ytdlpExecutableCache: (url: URL, prefix: [String])?

    public struct DownloadItem: Identifiable, Equatable {
        public let id = UUID()
        public let url: URL
        public var status: DownloadStatus
        public var outputFilename: String?
        public let createdAt: Date
        public var logs: String = ""

        public static func == (lhs: DownloadItem, rhs: DownloadItem) -> Bool {
            lhs.id == rhs.id
        }
    }

    private var persistenceURL: URL {
        Repo.dataDir.appendingPathComponent("downloads.json")
    }

    private init() {
        checkAvailability()
        load()
        var changed = false
        for i in items.indices {
            switch items[i].status {
            case .queued, .resolving, .downloading:
                items[i].status = .interrupted("Interrupted")
                changed = true
            default:
                break
            }
        }
        if changed {
            save()
            NotificationCenter.default.post(name: .musicFolderChanged, object: nil)
            IPC.post(IPC.Name.musicFolderChanged)
        }
    }

    private func save() {
        let saved = items.map {
            SavedItem(
                url: $0.url, status: $0.status, outputFilename: $0.outputFilename,
                createdAt: $0.createdAt)
        }
        if let data = try? JSONEncoder().encode(saved) {
            try? FileManager.default.createDirectory(
                at: Repo.dataDir, withIntermediateDirectories: true)
            try? data.write(to: persistenceURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL),
            let saved = try? JSONDecoder().decode([SavedItem].self, from: data)
        else { return }
        items = saved.map {
            DownloadItem(
                url: $0.url, status: $0.status, outputFilename: $0.outputFilename,
                createdAt: $0.createdAt)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func checkAvailability() {
        ytdlpExecutableCache = nil
        let (exe, prefix) = ytdlpExecutable()
        let p = Process()
        p.executableURL = exe
        p.arguments = prefix + ["--version"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                unavailableReason = nil
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                ytdlpVersion = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                unavailableReason =
                    "yt-dlp is not installed. Install it with Homebrew:\nbrew install yt-dlp"
                ytdlpVersion = nil
                ytdlpExecutableCache = nil
            }
        } catch {
            unavailableReason =
                "yt-dlp is not installed. Install it with Homebrew:\nbrew install yt-dlp"
            ytdlpVersion = nil
            ytdlpExecutableCache = nil
        }
    }

    public func updateYTDLP(completion: ((Result<String, Error>) -> Void)? = nil) {
        isUpdatingYTDLP = true
        updateResult = nil
        ytdlpUpdateMessage = nil
        let (exe, prefix) = ytdlpExecutable()
        let p = Process()
        p.executableURL = exe
        p.arguments = prefix + ["-U"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        p.terminationHandler = { [weak self] proc in
            let out =
                String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? ""
            let err =
                String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.isUpdatingYTDLP = false
                self.ytdlpExecutableCache = nil
                if proc.terminationStatus == 0 {
                    let msg = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    let text = msg.isEmpty ? "yt-dlp updated" : msg
                    self.updateResult = .success(text)
                    self.ytdlpUpdateMessage = text
                } else {
                    let msg = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    let text = msg.isEmpty ? "Update failed" : msg
                    let error = NSError(
                        domain: "YTDLP",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: text]
                    )
                    self.updateResult = .failure(error)
                    self.ytdlpUpdateMessage = text
                }
                self.checkAvailability()
                completion?(self.updateResult!)
            }
        }

        do {
            try p.run()
        } catch {
            isUpdatingYTDLP = false
            ytdlpExecutableCache = nil
            updateResult = .failure(error)
            ytdlpUpdateMessage = error.localizedDescription
            checkAvailability()
            completion?(updateResult!)
        }
    }

    public func parseURLs(from text: String) -> [URL] {
        text
            .components(separatedBy: CharacterSet([",", "\n", "\r"]))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
            .filter { isYouTubeURL($0) }
    }

    private func isYouTubeURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("youtube.com") || host.contains("youtu.be")
    }

    public func enqueue(urls: [URL], prefix: String) {
        let outputDir = Repo.musicDir
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let items = urls.map { url -> DownloadItem in
            let template: String
            if prefix.isEmpty {
                template = outputDir.appendingPathComponent("%(title)s.%(ext)s").path
            } else {
                template = outputDir.appendingPathComponent("\(prefix)%(title)s.%(ext)s").path
            }
            return DownloadItem(
                url: url, status: .queued, outputFilename: template, createdAt: Date())
        }
        self.items.insert(contentsOf: items, at: 0)
        save()
        if !isRunning {
            processNext()
        }
    }

    public func retry(_ item: DownloadItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].status = .queued
        save()
        if !isRunning {
            processNext()
        }
    }

    public func retryAll() {
        for i in items.indices {
            switch items[i].status {
            case .error, .interrupted:
                items[i].status = .queued
            default:
                break
            }
        }
        save()
        if !isRunning {
            processNext()
        }
    }

    public func clearHistory() {
        cancelAll()
        items.removeAll()
        save()
    }

    private func processNext() {
        guard let index = items.firstIndex(where: { $0.status == .queued }) else {
            isRunning = false
            currentItemID = nil
            currentProcess = nil
            return
        }
        isRunning = true
        let item = items[index]
        let itemID = item.id
        currentItemID = itemID
        items[index].status = .resolving
        save()

        let (exe, prefix) = ytdlpExecutable()
        let p = Process()
        p.executableURL = exe
        p.arguments =
            prefix + [
                "--no-update",
                "--no-playlist",
                "--no-quiet",
                "-x", "--audio-format", "m4a",
                "--embed-thumbnail", "--convert-thumbnails", "jpg",
                "--progress", "--newline",
                "-o", item.outputFilename ?? "%(title)s.%(ext)s",
                "--print", "after_move:filepath",
                item.url.absoluteString,
            ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let stream: @Sendable (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self, let index = self.indexOfItem(with: itemID) else { return }
                if case .interrupted = self.items[index].status { return }
                self.items[index].logs += text
                let (progress, videoIndex, videoCount) = self.parseProgress(from: text)
                self.items[index].status = .downloading(
                    progress: progress, videoIndex: videoIndex, videoCount: videoCount)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = stream
        errPipe.fileHandleForReading.readabilityHandler = stream

        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let tail =
                (String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    ?? "")
                + (String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    ?? "")

            Task { @MainActor in
                guard let self else { return }
                defer {
                    self.currentProcess = nil
                    self.currentItemID = nil
                    self.processNext()
                }
                guard let index = self.indexOfItem(with: itemID) else { return }
                if case .interrupted = self.items[index].status {
                    return
                }
                if !tail.isEmpty {
                    self.items[index].logs += tail
                }
                let producedPaths =
                    self.items[index].logs
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
                if proc.terminationStatus == 0 || !producedPaths.isEmpty {
                    let files = producedPaths.map { ($0 as NSString).lastPathComponent }
                    let label = files.isEmpty ? "done" : files.joined(separator: ", ")
                    self.items[index].status = .done(label)
                    self.save()
                    NotificationCenter.default.post(name: .musicFolderChanged, object: nil)
                    IPC.post(IPC.Name.musicFolderChanged)
                } else {
                    let msg = self.items[index].logs.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    self.items[index].status = .error(msg.isEmpty ? "Unknown error" : msg)
                    self.save()
                }
            }
        }

        p.environment = toolchainEnvironment()
        currentProcess = p
        do {
            try p.run()
        } catch {
            currentProcess = nil
            currentItemID = nil
            guard let index = indexOfItem(with: itemID) else {
                processNext()
                return
            }
            items[index].status = .error(error.localizedDescription)
            save()
            processNext()
        }
    }

    private func indexOfItem(with id: UUID) -> Int? {
        items.firstIndex(where: { $0.id == id })
    }

    private func toolchainEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let toolDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = env["PATH"].map { [$0] } ?? []
        env["PATH"] = (toolDirs + existing).joined(separator: ":")
        return env
    }

    private func ytdlpExecutable() -> (url: URL, prefix: [String]) {
        if let cached = ytdlpExecutableCache { return cached }

        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
        ]
        let fm = FileManager.default
        for path in candidates where fm.fileExists(atPath: path) {
            let result = (URL(fileURLWithPath: path), [String]())
            ytdlpExecutableCache = result
            return result
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            let localBin = (home as NSString).appendingPathComponent(".local/bin/yt-dlp")
            if fm.fileExists(atPath: localBin) {
                let result = (URL(fileURLWithPath: localBin), [String]())
                ytdlpExecutableCache = result
                return result
            }
        }
        let result = (URL(fileURLWithPath: "/usr/bin/env"), ["yt-dlp"])
        ytdlpExecutableCache = result
        return result
    }

    public func cancelAll() {
        currentProcess?.terminate()
        currentProcess = nil
        for i in items.indices {
            switch items[i].status {
            case .queued, .resolving, .downloading:
                items[i].status = .interrupted("Cancelled")
            default:
                break
            }
        }
        isRunning = false
        currentItemID = nil
        save()
    }

    private func parseProgress(from text: String) -> (
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
