import AppKit
import Foundation

extension Notification.Name {
    public static let musicFolderChanged = Notification.Name("musicFolderChanged")
}

public enum DownloadStatus: Equatable {
    case queued
    case downloading(progress: String)
    case done(output: String)
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
                unavailableReason = "yt-dlp is not installed. Install it with Homebrew:\nbrew install yt-dlp"
            }
        } catch {
            unavailableReason = "yt-dlp is not installed. Install it with Homebrew:\nbrew install yt-dlp"
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
        items[index].status = .downloading(progress: "starting...")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [
            "yt-dlp", "-x", "--audio-format", "m4a",
            "--embed-thumbnail", "--convert-thumbnails", "jpg",
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
                let progress = self.parseProgress(from: text)
                if let progress {
                    self.items[index].status = .downloading(progress: progress)
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()

            Task { @MainActor in
                guard let self, index < self.items.count else { return }
                if proc.terminationStatus == 0 {
                    let files = String(data: outData, encoding: .utf8)?
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .compactMap { URL(string: $0)?.lastPathComponent } ?? []
                    let label = files.isEmpty ? "done" : files.joined(separator: ", ")
                    self.items[index].status = .done(output: label)
                    NotificationCenter.default.post(name: .musicFolderChanged, object: nil)
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(
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

    private func parseProgress(from text: String) -> String? {
        let patterns = [
            #"(\d+\.\d+)%\s*of\s*~?\s*[\d.]+\w+ at"#,
            #"(\d+\.\d+)%\s*of"#,
            #"\[download\]\s+(\d+\.\d+)%"#,
        ]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let match = String(text[range])
                if let pct = match.components(separatedBy: "%").first?.trimmingCharacters(
                    in: .whitespaces)
                    .components(separatedBy: " ").last
                {
                    return "\(pct)%"
                }
            }
        }
        if text.contains("[ExtractAudio]") { return "Converting..." }
        if text.contains("[Metadata]") { return "Adding metadata..." }
        if text.contains("[Merger]") { return "Merging..." }
        return nil
    }
}
