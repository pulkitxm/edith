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
            DownloadListCommand.self, DownloadAddCommand.self, DownloadRetryCommand.self,
            DownloadRemoveCommand.self, DownloadClearCommand.self, DownloadToolCommand.self,
            DownloadCancelCommand.self,
        ],
        defaultSubcommand: DownloadListCommand.self,
        aliases: ["downloads", "dl"])
}

enum DownloadBridge {
    static func records() -> [DownloadRecord] { DownloadQueue.load() }

    static func record(at index: Int) throws -> (record: DownloadRecord, all: [DownloadRecord]) {
        let all = records()
        guard !all.isEmpty else {
            throw CLIFailure.unavailable("the download queue is empty")
        }
        guard index >= 1, index <= all.count else {
            throw CLIFailure.notFound(
                "there is no download \(index)",
                hint: "the queue holds \(all.count), numbered from 1")
        }
        return (all[index - 1], all)
    }

    static func json(_ record: DownloadRecord, index: Int) -> JSONValue {
        .object([
            "index": .int(index),
            "url": .string(record.url.absoluteString),
            "title": .string(record.title),
            "state": .string(record.state),
            "detail": .string(record.detail),
            "kind": .string(record.kind?.rawValue ?? "audio"),
            "queuedAt": .date(record.createdAt),
        ])
    }

    static func announce() {
        AppBridge.post(IPC.Name.downloadQueueChanged)
    }

    static func note(_ changed: Int) {
        guard changed > 0, !AppBridge.helperIsRunning else { return }
        CLIOut.note("Edith is not running, so this starts when you next open it")
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
            var all = DownloadBridge.records()
            if active { all = all.filter { !$0.isFinished } }
            let shown = limit == 0 ? all : Array(all.prefix(limit))
            guard !json else {
                CLIOut.json(
                    .array(shown.enumerated().map { DownloadBridge.json($1, index: $0 + 1) }))
                return
            }
            guard !shown.isEmpty else {
                CLIOut.note(active ? "nothing is downloading" : "the download queue is empty")
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["#", "STATE", "KIND", "WHAT"],
                    rows: shown.enumerated().map { offset, record in
                        [
                            String(offset + 1), record.state, record.kind?.rawValue ?? "audio",
                            record.title,
                        ]
                    }))
            guard shown.count < all.count else { return }
            CLIOut.note("showing \(shown.count) of \(all.count); pass --limit 0 for all of them")
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
            let added = try DownloadQueue.enqueue(urls: parsed, prefix: prefix, kind: wanted)
            DownloadBridge.announce()
            guard !json else {
                CLIOut.json(
                    .array(added.enumerated().map { DownloadBridge.json($1, index: $0 + 1) }))
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
                changed = try DownloadQueue.retry { $0.canRetry }
            } else {
                guard let index else {
                    throw CLIFailure(
                        "say which download to retry", hint: "pass a number, or --all")
                }
                let found = try DownloadBridge.record(at: index)
                guard found.record.canRetry else {
                    throw CLIFailure(
                        "download \(index) is \(found.record.state), so there is nothing to retry")
                }
                changed = try DownloadQueue.retry { $0.url == found.record.url }
            }
            DownloadBridge.announce()
            guard !json else {
                CLIOut.json(.object(["retried": .int(changed)]))
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

    @Argument(help: "The download number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let found = try DownloadBridge.record(at: index)
            let removed = try DownloadQueue.remove {
                $0.url == found.record.url && $0.createdAt == found.record.createdAt
            }
            DownloadBridge.announce()
            guard !json else {
                CLIOut.json(
                    .object([
                        "removed": .int(removed),
                        "remaining": .int(DownloadQueue.load().count),
                    ]))
                return
            }
            CLIOut.out("removed \(found.record.title)")
        }
    }
}

struct DownloadClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Forget everything that has finished.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Clear what is still queued or running too.")
    var everything = false

    func run() async throws {
        try await execute {
            let removed =
                everything
                ? try DownloadQueue.remove { _ in true } : try DownloadQueue.clearFinished()
            DownloadBridge.announce()
            guard !json else {
                CLIOut.json(
                    .object([
                        "removed": .int(removed),
                        "remaining": .int(DownloadQueue.load().count),
                    ]))
                return
            }
            CLIOut.out("cleared \(removed)")
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
                let version = executable.flatMap(DownloadTool.version(of:))
                guard !json else {
                    CLIOut.json(
                        .object([
                            "installed": .bool(executable != nil),
                            "path": .optional(executable?.path),
                            "version": .optional(version),
                        ]))
                    return
                }
                guard let executable else {
                    throw CLIFailure.unavailable(
                        "yt-dlp is not installed",
                        hint: "install it in Edith under Music, or with `brew install yt-dlp`")
                }
                CLIOut.out("\(version ?? "unknown")  \(executable.path)")
                return
            }
            guard let executable else {
                throw CLIFailure.unavailable(
                    "yt-dlp is not installed, so there is nothing to update",
                    hint: "install it in Edith under Music, or with `brew install yt-dlp`")
            }
            let before = DownloadTool.version(of: executable)
            let output = DownloadTool.selfUpdate(executable)
            let after = DownloadTool.version(of: executable)
            guard !json else {
                CLIOut.json(
                    .object([
                        "path": .string(executable.path),
                        "before": .optional(before),
                        "after": .optional(after),
                        "changed": .bool(before != after),
                    ]))
                return
            }
            CLIOut.out(output.isEmpty ? "yt-dlp is \(after ?? "unknown")" : output)
        }
    }
}

enum DownloadTool {
    static func version(of executable: URL) -> String? {
        let output = run(executable, ["--version"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func selfUpdate(_ executable: URL) -> String {
        run(executable, ["-U"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(_ executable: URL, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = CLIToolEnvironment.sanitized()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

struct DownloadCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Stop what is downloading and empty the rest of the queue.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let pending = DownloadQueue.load().filter { !$0.isFinished }
            guard !pending.isEmpty else {
                guard !json else {
                    CLIOut.json(
                        .object([
                            "cancelled": .int(0), "stoppedRunning": .bool(false),
                            "appRunning": .bool(AppBridge.mainAppIsRunning),
                        ]))
                    return
                }
                CLIOut.note("nothing is downloading")
                return
            }
            let appRunning = AppBridge.mainAppIsRunning
            if appRunning { AppBridge.post(IPC.Name.requestDownloadCancel) }
            let stopped = try DownloadQueue.remove { !$0.isFinished }
            DownloadBridge.announce()
            guard !json else {
                CLIOut.json(
                    .object([
                        "cancelled": .int(stopped), "stoppedRunning": .bool(appRunning),
                        "appRunning": .bool(appRunning),
                    ]))
                return
            }
            CLIOut.out("cancelled \(stopped)")
            if !appRunning {
                CLIOut.note(
                    "Edith was not running, so the queue was emptied without stopping yt-dlp")
            }
        }
    }
}
