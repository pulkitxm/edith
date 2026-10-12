import EdithExtensionSupport
import Foundation

public struct DownloadRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var url: URL
    public var status: DownloadStatus
    public var outputFilename: String?
    public var createdAt: Date
    public var kind: DownloadKind?
    public var resultPaths: [String]?
    public var browser: DownloadBrowser?

    public init(
        id: UUID = UUID(), url: URL, status: DownloadStatus, outputFilename: String?,
        createdAt: Date,
        kind: DownloadKind?, resultPaths: [String]? = nil, browser: DownloadBrowser? = nil
    ) {
        self.id = id
        self.url = url
        self.status = status
        self.outputFilename = outputFilename
        self.createdAt = createdAt
        self.kind = kind
        self.resultPaths = resultPaths
        self.browser = browser
    }

    public var state: String {
        switch status {
        case .queued: return "queued"
        case .resolving: return "resolving"
        case .downloading: return "downloading"
        case .done: return "done"
        case .error: return "failed"
        case .interrupted: return "interrupted"
        }
    }

    public var detail: String {
        switch status {
        case let .downloading(progress, index, count):
            return count > 1 ? "\(progress) (\(index)/\(count))" : progress
        case let .done(output): return output
        case let .error(message): return message
        case let .interrupted(reason): return reason ?? ""
        case .queued, .resolving: return ""
        }
    }

    public var isFinished: Bool {
        switch status {
        case .done, .error, .interrupted: return true
        case .queued, .resolving, .downloading: return false
        }
    }

    public var canRetry: Bool {
        switch status {
        case .error, .interrupted: return true
        default: return false
        }
    }

    public var title: String {
        if case let .done(output) = status {
            let first = output.components(separatedBy: ", ").first ?? output
            let stem = (first as NSString).deletingPathExtension
            if !stem.isEmpty { return (stem as NSString).lastPathComponent }
        }
        return url.absoluteString
    }
}

public enum DownloadQueue {
    public static var file: URL {
        DownloadsStorage.dataDir.appendingPathComponent("downloads.json")
    }

    public static func load(from file: URL = DownloadQueue.file) -> [DownloadRecord] {
        (try? read(from: file)) ?? []
    }

    public static func read(from file: URL = DownloadQueue.file) throws -> [DownloadRecord] {
        try PersistentJSONFile.read([DownloadRecord].self, from: file, missing: []).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public static func update<Result>(
        file: URL = DownloadQueue.file, _ mutation: (inout [DownloadRecord]) throws -> Result
    ) throws -> ([DownloadRecord], Result) {
        try PersistentJSONFile.update([DownloadRecord].self, at: file, missing: [], mutation)
    }

    public static func save(_ records: [DownloadRecord], to file: URL = DownloadQueue.file) throws {
        _ = try update(file: file) { $0 = records }
    }

    public static func outputTemplate(
        prefix: String, directory: URL = DownloadsStorage.audioDirectory
    )
        -> String
    {
        let escaped = prefix.replacingOccurrences(of: "%", with: "%%")
        let name = "\(escaped)%(title).160B [%(id)s].%(ext)s"
        return directory.appendingPathComponent(name).path
    }

    @discardableResult
    public static func enqueue(
        urls: [URL], prefix: String = "", kind: DownloadKind = .audio, now: Date = Date(),
        file: URL = DownloadQueue.file, outputDirectory: URL = DownloadsStorage.audioDirectory,
        browser: DownloadBrowser? = nil
    ) throws -> [DownloadRecord] {
        let template = outputTemplate(prefix: prefix, directory: outputDirectory)
        let added = urls.map {
            DownloadRecord(
                url: $0, status: .queued, outputFilename: template, createdAt: now, kind: kind,
                browser: browser)
        }
        _ = try update(file: file) { $0.insert(contentsOf: added, at: 0) }
        return added
    }

    @discardableResult
    public static func retry(
        _ matching: (DownloadRecord) -> Bool, file: URL = DownloadQueue.file
    ) throws -> Int {
        try update(file: file) { records in
            var changed = 0
            for index in records.indices where matching(records[index]) && records[index].canRetry {
                records[index].status = .queued
                changed += 1
            }
            return changed
        }.1
    }

    @discardableResult
    public static func remove(
        _ matching: (DownloadRecord) -> Bool, file: URL = DownloadQueue.file
    ) throws -> Int {
        try update(file: file) { records in
            let count = records.count
            records.removeAll(where: matching)
            return count - records.count
        }.1
    }

    @discardableResult
    public static func clearFinished(file: URL = DownloadQueue.file) throws -> Int {
        try remove({ $0.isFinished }, file: file)
    }
}
