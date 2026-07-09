import AppKit
import Foundation

extension Notification.Name {
    public static let musicFolderChanged = Notification.Name("musicFolderChanged")
}

public enum DownloadStatus: Equatable {
    case queued
    case resolving
    case downloading(progress: String, videoIndex: Int, videoCount: Int)
    case done(String)
    case error(String)
}

@MainActor
public final class YoutubeDownloader: ObservableObject {
    public static let shared = YoutubeDownloader()

    @Published public private(set) var items: [DownloadItem] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var unavailableReason: String?

    private var currentProcess: Process?

    public struct DownloadItem: Identifiable, Equatable {
        public let id = UUID()
        public let url: URL
        public var status: DownloadStatus
        public var outputFilename: String?

        public static func == (lhs: DownloadItem, rhs: DownloadItem) -> Bool {
            lhs.id == rhs.id
        }
    }

    private init() {
        checkAvailability()
    }

    public func checkAvailability() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["yt-dlp", "--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                unavailableReason = nil
            } else {
                unavailableReason =
                    "yt-dlp is not installed. Install it with Homebrew:\nbrew install yt-dlp"
            }
        } catch {
            unavailableReason =
                "yt-dlp is not installed. Install it with Homebrew:\nbrew install yt-dlp"
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
            return DownloadItem(url: url, status: .queued, outputFilename: template)
        }
        self.items.append(contentsOf: items)
        if !isRunning {
            processNext()
        }
    }

    private func processNext() {
        guard let index = items.firstIndex(where: { $0.status == .queued }) else {
            isRunning = false
            return
        }
        isRunning = true
        let item = items[index]
        items[index].status = .resolving

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [
            "yt-dlp", "-x", "--audio-format", "m4a",
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

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self, index < self.items.count else { return }
                let (progress, videoIndex, videoCount) = self.parseProgress(from: text)
                self.items[index].status = .downloading(
                    progress: progress, videoIndex: videoIndex, videoCount: videoCount)
            }
        }

        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()

            Task { @MainActor in
                guard let self, index < self.items.count else { return }
                if proc.terminationStatus == 0 {
                    let files =
                        String(data: outData, encoding: .utf8)?
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .compactMap { URL(string: $0)?.lastPathComponent } ?? []
                    let label = files.isEmpty ? "done" : files.joined(separator: ", ")
                    self.items[index].status = .done(label)
                    NotificationCenter.default.post(name: .musicFolderChanged, object: nil)
                    IPC.post(IPC.Name.musicFolderChanged)
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg =
                        String(data: errData, encoding: .utf8)?.trimmingCharacters(
                            in: .whitespacesAndNewlines) ?? "Unknown error"
                    self.items[index].status = .error(msg)
                }
                self.processNext()
            }
        }

        currentProcess = p
        do {
            try p.run()
        } catch {
            items[index].status = .error(error.localizedDescription)
            processNext()
        }
    }

    public func cancelAll() {
        currentProcess?.terminate()
        currentProcess = nil
        items.removeAll()
        isRunning = false
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
