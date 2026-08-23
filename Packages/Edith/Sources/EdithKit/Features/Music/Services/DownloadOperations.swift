import AppKit
import EdithCore
import Foundation

public enum DownloadOperation: String, CaseIterable, Sendable {
    case list
    case status
    case enqueue
    case cancel
    case retry
    case remove
    case clear
    case reveal
    case open
    case tool

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: operationID), summary: summary,
            cli: ["download", command], effect: effect, requiresPreview: requiresPreview)
    }

    private var operationID: String {
        switch self {
        case .tool: "download.tool"
        default: "download.queue.\(rawValue)"
        }
    }

    private var command: String {
        switch self {
        case .list: "ls"
        case .enqueue: "add"
        case .remove: "rm"
        case .tool: "tool"
        default: rawValue
        }
    }

    private var summary: String {
        switch self {
        case .list: "List the download queue."
        case .status: "Summarize download lifecycle states."
        case .enqueue: "Queue one or more downloads."
        case .cancel: "Cancel queued and running downloads."
        case .retry: "Queue failed or interrupted downloads again."
        case .remove: "Remove one download record."
        case .clear: "Clear download history."
        case .reveal: "Reveal completed download results in Finder."
        case .open: "Open completed download results."
        case .tool: "Report or update the yt-dlp installation."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .list, .status: .read
        case .remove, .clear: .destructive
        case .reveal, .open: .interactive
        case .enqueue, .cancel, .retry, .tool: .write
        }
    }

    private var requiresPreview: Bool {
        self == .remove || self == .clear
    }
}

public struct DownloadToolStatus: Equatable, Sendable {
    public let executable: URL?
    public let version: String?

    public var installed: Bool { executable != nil && version != nil }
}

public struct DownloadToolUpdate: Equatable, Sendable {
    public let executable: URL
    public let before: String?
    public let after: String?
    public let output: String

    public var changed: Bool { before != after }
}

public enum DownloadToolOperationError: LocalizedError, Equatable {
    case missing
    case failed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .missing: "yt-dlp is not installed, so there is nothing to update."
        case .failed(let output, let status):
            output.isEmpty ? "yt-dlp update exited with status \(status)." : output
        }
    }
}

public enum DownloadToolOperationExecution {
    public static func status(
        executable: URL?, runCommand: @escaping ToolVersionProbe.RunCommand = {
            try await CLICommandRunner.run($0, onLine: $1)
        }
    ) async -> DownloadToolStatus {
        guard let executable else { return DownloadToolStatus(executable: nil, version: nil) }
        let request = CLICommandRequest(
            executableURL: executable, arguments: ["--version"],
            environment: CLIToolEnvironment.sanitized(), timeout: 5)
        return DownloadToolStatus(
            executable: executable,
            version: await ToolVersionProbe.version(request, runCommand: runCommand))
    }

    public static func update(
        executable: URL?, runCommand: @escaping ToolVersionProbe.RunCommand = {
            try await CLICommandRunner.run($0, onLine: $1)
        }
    ) async throws -> DownloadToolUpdate {
        guard let executable else { throw DownloadToolOperationError.missing }
        let before = await status(executable: executable, runCommand: runCommand).version
        let request = CLICommandRequest(
            executableURL: executable, arguments: ["-U"],
            environment: CLIToolEnvironment.sanitized(), timeout: 120)
        let result = try await runCommand(request, { _ in })
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.terminationStatus == 0 else {
            throw DownloadToolOperationError.failed(output, result.terminationStatus)
        }
        let after = await status(executable: executable, runCommand: runCommand).version
        return DownloadToolUpdate(
            executable: executable, before: before, after: after, output: output)
    }
}

public struct DownloadQueueSnapshot: Equatable, Sendable {
    public let records: [DownloadRecord]
    public let queued: Int
    public let resolving: Int
    public let downloading: Int
    public let done: Int
    public let failed: Int
    public let interrupted: Int

    public init(records: [DownloadRecord]) {
        self.records = records
        queued = records.count { $0.status == .queued }
        resolving = records.count { $0.status == .resolving }
        downloading = records.count {
            if case .downloading = $0.status { return true }
            return false
        }
        done = records.count {
            if case .done = $0.status { return true }
            return false
        }
        failed = records.count {
            if case .error = $0.status { return true }
            return false
        }
        interrupted = records.count {
            if case .interrupted = $0.status { return true }
            return false
        }
    }

    public var total: Int { records.count }
    public var active: Int { queued + resolving + downloading }
    public var finished: Int { done + failed + interrupted }
}

public struct DownloadMutationResult: Equatable, Sendable {
    public let changed: Int
    public let records: [DownloadRecord]

    public init(changed: Int, records: [DownloadRecord]) {
        self.changed = changed
        self.records = records
    }

    public var remaining: Int { records.count }
}

public enum DownloadOperationError: LocalizedError, Equatable {
    case empty
    case missingIndex(Int, count: Int)
    case notRetryable(Int, state: String)
    case notCancelable(Int, state: String)
    case noResult(Int)
    case missingResult(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "The download queue is empty."
        case .missingIndex(let index, let count):
            "There is no download \(index); the queue holds \(count)."
        case .notRetryable(let index, let state):
            "Download \(index) is \(state), so there is nothing to retry."
        case .notCancelable(let index, let state):
            "Download \(index) is \(state), so there is nothing to cancel."
        case .noResult(let index): "Download \(index) has no completed result."
        case .missingResult(let path): "The completed result is missing at \(path)."
        }
    }
}

public enum DownloadOperationExecution {
    public static func list(
        activeOnly: Bool = false, limit: Int = 25, file: URL = DownloadQueue.file
    ) -> [DownloadRecord] {
        let records = DownloadQueue.load(from: file)
        let filtered = activeOnly ? records.filter { !$0.isFinished } : records
        return limit == 0 ? filtered : Array(filtered.prefix(max(0, limit)))
    }

    public static func status(file: URL = DownloadQueue.file) -> DownloadQueueSnapshot {
        DownloadQueueSnapshot(records: DownloadQueue.load(from: file))
    }

    public static func record(
        at index: Int, file: URL = DownloadQueue.file
    ) throws -> DownloadRecord {
        let records = DownloadQueue.load(from: file)
        guard !records.isEmpty else { throw DownloadOperationError.empty }
        guard index > 0, index <= records.count else {
            throw DownloadOperationError.missingIndex(index, count: records.count)
        }
        return records[index - 1]
    }

    public static func enqueue(
        urls: [URL], prefix: String = "", kind: DownloadKind = .audio,
        now: Date = Date(), file: URL = DownloadQueue.file,
        outputDirectory: URL = Repo.musicDir
    ) throws -> [DownloadRecord] {
        try DownloadQueue.enqueue(
            urls: urls, prefix: prefix, kind: kind, now: now, file: file,
            outputDirectory: outputDirectory)
    }

    public static func retry(
        id: UUID? = nil, all: Bool = false, file: URL = DownloadQueue.file
    ) throws -> DownloadMutationResult {
        let changed = try DownloadQueue.retry(
            { record in all ? record.canRetry : record.id == id }, file: file)
        return DownloadMutationResult(changed: changed, records: DownloadQueue.load(from: file))
    }

    public static func retry(
        index: Int, file: URL = DownloadQueue.file
    ) throws -> DownloadMutationResult {
        let record = try record(at: index, file: file)
        guard record.canRetry else {
            throw DownloadOperationError.notRetryable(index, state: record.state)
        }
        return try retry(id: record.id, file: file)
    }

    public static func cancel(
        id: UUID? = nil, includeQueued: Bool = true, reason: String = "Cancelled",
        file: URL = DownloadQueue.file
    ) throws -> DownloadMutationResult {
        var records = DownloadQueue.load(from: file)
        var changed = 0
        for index in records.indices where id == nil || records[index].id == id {
            let cancellable = switch records[index].status {
            case .queued: includeQueued
            case .resolving, .downloading: true
            case .done, .error, .interrupted: false
            }
            guard cancellable else { continue }
            records[index].status = .interrupted(reason)
            changed += 1
        }
        if changed > 0 { try DownloadQueue.save(records, to: file) }
        return DownloadMutationResult(changed: changed, records: records)
    }

    public static func cancel(
        index: Int, reason: String = "Cancelled", file: URL = DownloadQueue.file
    ) throws -> DownloadMutationResult {
        let record = try record(at: index, file: file)
        guard !record.isFinished else {
            throw DownloadOperationError.notCancelable(index, state: record.state)
        }
        return try cancel(id: record.id, reason: reason, file: file)
    }

    public static func remove(
        id: UUID, file: URL = DownloadQueue.file
    ) throws -> DownloadMutationResult {
        let changed = try DownloadQueue.remove({ $0.id == id }, file: file)
        return DownloadMutationResult(changed: changed, records: DownloadQueue.load(from: file))
    }

    public static func remove(
        index: Int, file: URL = DownloadQueue.file
    ) throws -> DownloadMutationResult {
        try remove(id: record(at: index, file: file).id, file: file)
    }

    public static func clear(
        includeActive: Bool = false, file: URL = DownloadQueue.file
    ) throws -> DownloadMutationResult {
        let changed = try DownloadQueue.remove(
            { includeActive || $0.isFinished }, file: file)
        return DownloadMutationResult(changed: changed, records: DownloadQueue.load(from: file))
    }

    public static func resultURLs(
        id: UUID, root: URL = Repo.musicDir, file: URL = DownloadQueue.file,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> [URL] {
        let records = DownloadQueue.load(from: file)
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw DownloadOperationError.empty
        }
        let position = index + 1
        guard case .done(let output) = records[index].status else {
            throw DownloadOperationError.noResult(position)
        }
        let urls = output.components(separatedBy: ", ").filter { !$0.isEmpty }.map {
            root.appendingPathComponent(($0 as NSString).lastPathComponent)
        }
        guard !urls.isEmpty else { throw DownloadOperationError.noResult(position) }
        if let missing = urls.first(where: { !exists($0.path) }) {
            throw DownloadOperationError.missingResult(missing.path)
        }
        return urls
    }

    @MainActor
    public static func reveal(
        id: UUID, root: URL = Repo.musicDir, file: URL = DownloadQueue.file,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        using reveal: @MainActor ([URL]) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting($0)
        }
    ) throws -> [URL] {
        let urls = try resultURLs(id: id, root: root, file: file, exists: exists)
        reveal(urls)
        return urls
    }

    @MainActor
    public static func open(
        id: UUID, root: URL = Repo.musicDir, file: URL = DownloadQueue.file,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        using open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) throws -> [URL] {
        let urls = try resultURLs(id: id, root: root, file: file, exists: exists)
        for url in urls { _ = open(url) }
        return urls
    }
}

enum DownloadProcessControl {
    static func cancel(
        currentID: UUID?, targetID: UUID?, terminate: () -> Void
    ) -> Bool {
        guard currentID != nil, targetID == nil || currentID == targetID else { return false }
        terminate()
        return true
    }
}
