import Foundation

public struct DownloadRecord: Codable, Equatable {
    public var url: URL
    public var status: DownloadStatus
    public var outputFilename: String?
    public var createdAt: Date
    public var kind: DownloadKind?

    public init(
        url: URL, status: DownloadStatus, outputFilename: String?, createdAt: Date,
        kind: DownloadKind?
    ) {
        self.url = url
        self.status = status
        self.outputFilename = outputFilename
        self.createdAt = createdAt
        self.kind = kind
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
    public static var file: URL { Repo.dataDir.appendingPathComponent("downloads.json") }

    public static func load() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return ((try? JSONDecoder().decode([DownloadRecord].self, from: data)) ?? [])
            .sorted { $0.createdAt > $1.createdAt }
    }

    public static func save(_ records: [DownloadRecord]) throws {
        try FileManager.default.createDirectory(
            at: Repo.dataDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
    }

    public static func outputTemplate(prefix: String) -> String {
        let directory = Repo.musicDir
        let name = prefix.isEmpty ? "%(title)s.%(ext)s" : "\(prefix)%(title)s.%(ext)s"
        return directory.appendingPathComponent(name).path
    }

    @discardableResult
    public static func enqueue(
        urls: [URL], prefix: String = "", kind: DownloadKind = .audio, now: Date = Date()
    ) throws -> [DownloadRecord] {
        let template = outputTemplate(prefix: prefix)
        let added = urls.map {
            DownloadRecord(
                url: $0, status: .queued, outputFilename: template, createdAt: now, kind: kind)
        }
        try save(added + load())
        return added
    }

    @discardableResult
    public static func retry(_ matching: (DownloadRecord) -> Bool) throws -> Int {
        var records = load()
        var changed = 0
        for index in records.indices where matching(records[index]) {
            guard records[index].canRetry else { continue }
            records[index].status = .queued
            changed += 1
        }
        guard changed > 0 else { return 0 }
        try save(records)
        return changed
    }

    @discardableResult
    public static func remove(_ matching: (DownloadRecord) -> Bool) throws -> Int {
        let records = load()
        let kept = records.filter { !matching($0) }
        guard kept.count != records.count else { return 0 }
        try save(kept)
        return records.count - kept.count
    }

    @discardableResult
    public static func clearFinished() throws -> Int {
        try remove { $0.isFinished }
    }
}
