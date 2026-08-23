import ArgumentParser
import EdithKit
import Foundation

struct DownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "The download queue Edith feeds to yt-dlp.",
        discussion: """
            The queue is a file, so listing it, adding to it and clearing it work whether
            or not the app is running. Edith is what actually runs yt-dlp, so anything
            added while it is closed waits in the queue and starts when you open it.
            """,
        subcommands: [
            DownloadListCommand.self, DownloadStatusCommand.self, DownloadAddCommand.self,
            DownloadRetryCommand.self, DownloadRemoveCommand.self, DownloadClearCommand.self,
            DownloadOpenCommand.self, DownloadRevealCommand.self, DownloadToolCommand.self,
            DownloadCancelCommand.self,
        ],
        defaultSubcommand: DownloadListCommand.self,
        aliases: ["downloads", "dl"])
}

enum DownloadBridge {
    static var file: URL { CLIEnvironment.downloadQueueFile }

    static func records() -> [DownloadRecord] {
        DownloadOperationExecution.list(limit: 0, file: file)
    }

    static func record(at index: Int) throws -> DownloadRecord {
        do { return try DownloadOperationExecution.record(at: index, file: file) } catch {
            throw failure(error)
        }
    }

    static func json(_ record: DownloadRecord, index: Int) -> JSONValue {
        .object([
            "index": .int(index),
            "id": .string(record.id.uuidString),
            "url": .string(record.url.absoluteString),
            "title": .string(record.title),
            "state": .string(record.state),
            "detail": .string(record.detail),
            "kind": .string(record.kind?.rawValue ?? "audio"),
            "queuedAt": .date(record.createdAt),
        ])
    }

    static func index(of record: DownloadRecord, in records: [DownloadRecord]) -> Int {
        (records.firstIndex { $0.id == record.id } ?? -1) + 1
    }

    static func announce() {
        AppBridge.post(IPC.Name.downloadQueueChanged)
    }

    static func note(_ changed: Int) {
        guard changed > 0, !AppBridge.helperIsRunning else { return }
        CLIOut.note("Edith is not running, so this starts when you next open it")
    }

    static func failure(_ error: Error) -> CLIFailure {
        guard let error = error as? DownloadOperationError else {
            return CLIFailure(error.localizedDescription)
        }
        switch error {
        case .empty:
            return .unavailable("the download queue is empty")
        case .missingIndex(let index, let count):
            return .notFound(
                "there is no download \(index)",
                hint: "the queue holds \(count), numbered from 1")
        case .notRetryable(let index, let state):
            return CLIFailure("download \(index) is \(state), so there is nothing to retry")
        case .notCancelable(let index, let state):
            return CLIFailure("download \(index) is \(state), so there is nothing to cancel")
        case .noResult(let index):
            return .unavailable(
                "download \(index) has no completed result",
                hint: "use `ed download ls` to choose a completed download")
        case .missingResult(let path):
            return .notFound("the completed result is missing", hint: path)
        }
    }
}

struct DownloadListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List the download queue, newest first.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Only the ones that have not finished.")
    var active = false

    @Option(help: "Show at most this many. Pass 0 for all of them.")
    var limit: Int = 25

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            let records = DownloadOperationExecution.list(limit: 0, file: DownloadBridge.file)
            let all = active ? records.filter { !$0.isFinished } : records
            let shown = limit == 0 ? all : Array(all.prefix(limit))
            guard !json else {
                CLIOut.json(
                    .array(
                        shown.map {
                            DownloadBridge.json(
                                $0, index: DownloadBridge.index(of: $0, in: records))
                        }))
                return
            }
            guard !shown.isEmpty else {
                CLIOut.note(active ? "nothing is downloading" : "the download queue is empty")
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["#", "STATE", "KIND", "WHAT"],
                    rows: shown.map { record in
                        [
                            String(DownloadBridge.index(of: record, in: records)), record.state,
                            record.kind?.rawValue ?? "audio",
                            record.title,
                        ]
                    }))
            guard shown.count < all.count else { return }
            CLIOut.note("showing \(shown.count) of \(all.count); pass --limit 0 for all of them")
        }
    }
}

struct DownloadStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Summarize every download lifecycle state.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let status = DownloadOperationExecution.status(file: DownloadBridge.file)
            let fields: [(String, Int)] = [
                ("total", status.total), ("active", status.active), ("queued", status.queued),
                ("resolving", status.resolving), ("downloading", status.downloading),
                ("done", status.done), ("failed", status.failed),
                ("interrupted", status.interrupted),
            ]
            guard !json else {
                CLIOut.json(
                    .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.0, .int($0.1)) })))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: fields.map { $0.0.uppercased() },
                    rows: [fields.map { String($0.1) }]))
        }
    }
}

struct DownloadAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Queue one or more URLs.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "What to fetch: audio or video.")
    var kind: String = "audio"

    @Option(help: "Prefix for the saved filename.")
    var prefix: String = ""

    @Argument(help: "The URLs to download.")
    var urls: [String]

    func run() async throws {
        try await execute {
            guard let wanted = DownloadKind(rawValue: kind) else {
                throw CLIFailure.notFound(
                    "no download kind called \(kind)",
                    hint: "kinds: " + DownloadKind.allCases.map(\.rawValue).joined(separator: ", "))
            }
            let parsed = YoutubeDownloader.parseURLs(from: urls.joined(separator: "\n"))
            guard !parsed.isEmpty else {
                throw CLIFailure(
                    "none of that looked like a URL",
                    hint: "pass a link, for example https://youtu.be/dQw4w9WgXcQ")
            }
            let added = try DownloadOperationExecution.enqueue(
                urls: parsed, prefix: prefix, kind: wanted, file: DownloadBridge.file)
            let records = DownloadBridge.records()
            DownloadBridge.announce()
            guard !json else {
                CLIOut.json(
                    .array(
                        added.map {
                            DownloadBridge.json(
                                $0, index: DownloadBridge.index(of: $0, in: records))
                        }))
                return
            }
            for record in added { CLIOut.out("queued \(record.url.absoluteString)") }
            DownloadBridge.note(added.count)
        }
    }
}

struct DownloadRetryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retry", abstract: "Queue a failed download again.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Retry everything that failed.")
    var all = false

    @Argument(help: "The download number, counting from 1.")
    var index: Int?

    func run() async throws {
        try await execute {
            let changed: Int
            if all {
                changed = try DownloadOperationExecution.retry(
                    all: true, file: DownloadBridge.file
                ).changed
            } else {
                guard let index else {
                    throw CLIFailure(
                        "say which download to retry", hint: "pass a number, or --all")
                }
                do {
                    changed = try DownloadOperationExecution.retry(
                        index: index, file: DownloadBridge.file
                    ).changed
                } catch {
                    throw DownloadBridge.failure(error)
                }
            }
            DownloadBridge.announce()
            guard !json else {
                var object: [String: JSONValue] = ["retried": .int(changed)]
                if let index {
                    let queued = try DownloadBridge.record(at: index)
                    object["record"] = DownloadBridge.json(queued, index: index)
                }
                CLIOut.json(.object(object))
                return
            }
            CLIOut.out(changed == 1 ? "queued it again" : "queued \(changed) again")
            DownloadBridge.note(changed)
        }
    }
}

struct DownloadRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Take one entry out of the queue.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually remove the record. Without this, show a preview.")
    var yes = false

    @Argument(help: "The download number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let record = try DownloadBridge.record(at: index)
            guard yes else {
                guard !json else {
                    CLIOut.json(
                        .object([
                            "record": DownloadBridge.json(record, index: index),
                            "removed": .int(0), "remaining": .int(DownloadBridge.records().count),
                            "preview": .bool(true),
                        ]))
                    return
                }
                CLIOut.out("would remove \(record.title)")
                CLIOut.note("nothing was removed; pass --yes to go ahead")
                return
            }
            let result: DownloadMutationResult
            do {
                result = try DownloadOperationExecution.remove(
                    id: record.id, file: DownloadBridge.file)
            } catch { throw DownloadBridge.failure(error) }
            DownloadBridge.announce()
            guard !json else {
                CLIOut.json(
                    .object([
                        "removed": .int(result.changed), "remaining": .int(result.remaining),
                        "preview": .bool(false),
                        "record": DownloadBridge.json(record, index: index),
                    ]))
                return
            }
            CLIOut.out("removed \(record.title)")
        }
    }
}

struct DownloadClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Forget everything that has finished.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually clear the records. Without this, show a preview.")
    var yes = false

    func run() async throws {
        try await execute {
            let records = DownloadBridge.records()
            let candidates = records.filter(\.isFinished)
            guard yes else {
                guard !json else {
                    CLIOut.json(
                        .object([
                            "removed": .int(0), "wouldRemove": .int(candidates.count),
                            "remaining": .int(records.count), "preview": .bool(true),
                        ]))
                    return
                }
                CLIOut.out("would clear \(candidates.count)")
                CLIOut.note("nothing was cleared; pass --yes to go ahead")
                return
            }
            let result = try DownloadOperationExecution.clear(file: DownloadBridge.file)
            DownloadBridge.announce()
            guard !json else {
                CLIOut.json(
                    .object([
                        "removed": .int(result.changed), "remaining": .int(result.remaining),
                        "preview": .bool(false),
                    ]))
                return
            }
            CLIOut.out("cleared \(result.changed)")
        }
    }
}

struct DownloadOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open the completed files for one download.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The download number, counting from 1.")
    var index: Int

    func run() async throws {
        try await DownloadResultCommand.run(.open, index: index, json: json)
    }
}

struct DownloadRevealCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reveal", abstract: "Reveal the completed files for one download.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The download number, counting from 1.")
    var index: Int

    func run() async throws {
        try await DownloadResultCommand.run(.reveal, index: index, json: json)
    }
}

enum DownloadResultCommand {
    enum Action { case open, reveal }

    static func run(_ action: Action, index: Int, json: Bool) async throws {
        try await execute {
            let record = try DownloadBridge.record(at: index)
            let urls: [URL]
            do {
                urls = try await MainActor.run {
                    switch action {
                    case .open:
                        try DownloadOperationExecution.open(
                            id: record.id, file: DownloadBridge.file)
                    case .reveal:
                        try DownloadOperationExecution.reveal(
                            id: record.id, file: DownloadBridge.file)
                    }
                }
            } catch { throw DownloadBridge.failure(error) }
            guard !json else {
                CLIOut.json(
                    .object([
                        "index": .int(index),
                        "id": .string(record.id.uuidString),
                        "action": .string(action == .open ? "open" : "reveal"),
                        "files": .array(urls.map { .string($0.path) }),
                    ]))
                return
            }
            for url in urls { CLIOut.out(url.path) }
        }
    }
}

struct DownloadToolCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tool",
        abstract: "Report or update the yt-dlp that does the work.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Update it rather than just reporting the version.")
    var update = false

    func run() async throws {
        try await execute {
            let executable = CLIEnvironment.executableNamed("yt-dlp")
            guard update else {
                let status = await DownloadToolOperationExecution.status(executable: executable)
                guard !json else {
                    CLIOut.json(
                        .object([
                            "installed": .bool(status.installed),
                            "path": .optional(status.executable?.path),
                            "version": .optional(status.version),
                        ]))
                    return
                }
                guard let executable = status.executable, status.installed else {
                    throw CLIFailure.unavailable(
                        "yt-dlp is not installed",
                        hint: "install it in Edith under Music, or with `brew install yt-dlp`")
                }
                CLIOut.out("\(status.version ?? "unknown")  \(executable.path)")
                return
            }
            let result: DownloadToolUpdate
            do {
                result = try await DownloadToolOperationExecution.update(executable: executable)
            } catch DownloadToolOperationError.missing {
                throw CLIFailure.unavailable(
                    "yt-dlp is not installed, so there is nothing to update",
                    hint: "install it in Edith under Music, or with `brew install yt-dlp`")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "path": .string(result.executable.path),
                        "before": .optional(result.before),
                        "after": .optional(result.after),
                        "changed": .bool(result.changed),
                    ]))
                return
            }
            CLIOut.out(
                result.output.isEmpty ? "yt-dlp is \(result.after ?? "unknown")" : result.output)
        }
    }
}

struct DownloadCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Stop active downloads and keep them available to retry.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The download number, counting from 1. Omit it to cancel all.")
    var index: Int?

    func run() async throws {
        try await execute {
            let appRunning = AppBridge.mainAppIsRunning
            let targets: [(Int, DownloadRecord)]
            let result: DownloadMutationResult
            if let index {
                let record = try DownloadBridge.record(at: index)
                do {
                    result = try DownloadOperationExecution.cancel(
                        index: index, file: DownloadBridge.file)
                } catch { throw DownloadBridge.failure(error) }
                targets = [(index, record)]
            } else {
                let records = DownloadBridge.records()
                targets = records.enumerated().compactMap {
                    $0.element.isFinished ? nil : ($0.offset + 1, $0.element)
                }
                result = try DownloadOperationExecution.cancel(file: DownloadBridge.file)
            }
            let cancelled = targets.map { index, original in
                (index, result.records.first { $0.id == original.id } ?? original)
            }
            guard result.changed > 0 else {
                guard !json else {
                    CLIOut.json(
                        .object([
                            "cancelled": .int(0), "appNotified": .bool(false),
                            "appRunning": .bool(appRunning),
                            "records": .array([]),
                        ]))
                    return
                }
                CLIOut.note("nothing is downloading")
                return
            }
            if appRunning {
                let info = index == nil ? nil : ["id": cancelled[0].1.id.uuidString]
                AppBridge.post(IPC.Name.requestDownloadCancel, userInfo: info)
            }
            DownloadBridge.announce()
            guard !json else {
                CLIOut.json(
                    .object([
                        "cancelled": .int(result.changed), "appNotified": .bool(appRunning),
                        "appRunning": .bool(appRunning),
                        "records": .array(
                            cancelled.map { DownloadBridge.json($0.1, index: $0.0) }),
                    ]))
                return
            }
            if let target = cancelled.first, cancelled.count == 1 {
                CLIOut.out("cancelled \(target.1.title)")
            } else {
                CLIOut.out("cancelled \(result.changed)")
            }
            if !appRunning {
                CLIOut.note(
                    "Edith was not running, so queued entries were marked interrupted")
            }
        }
    }
}
