import AppKit
import ArgumentParser
import EdithKit
import Foundation

struct ClipboardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "The clipboard history Edith keeps.",
        discussion: """
            The history is a file on disk, so these read commands work whether or not
            the app is running. Entries are numbered from 1, newest first, and that
            number is what `get`, `copy` and `rm` take.
            """,
        subcommands: [
            ClipboardListCommand.self, ClipboardStatsCommand.self, ClipboardGetCommand.self,
            ClipboardCopyCommand.self, ClipboardPinCommand.self, ClipboardUnpinCommand.self,
            ClipboardRemoveCommand.self, ClipboardClearCommand.self,
        ],
        defaultSubcommand: ClipboardListCommand.self)
}

enum ClipboardBridge {
    static func entries(query: String = "") -> [ClipboardEntry] {
        ClipboardActions.listed(query: query, defaults: CLIEnvironment.sharedDefaults)
    }

    static func entry(at index: Int) throws -> (entry: ClipboardEntry, all: [ClipboardEntry]) {
        let all = entries()
        guard !all.isEmpty else {
            let recording =
                CLIEnvironment.sharedDefaults.object(forKey: AppStorageKeys.Clipboard.enabled)
                as? Bool ?? true
            throw CLIFailure.unavailable(
                "the clipboard history is empty",
                hint: recording
                    ? "Edith records what you copy while it is running"
                    : "turn the Clipboard extension on with `ed extensions enable clipboard`")
        }
        guard index >= 1, index <= all.count else {
            throw CLIFailure.notFound(
                "there is no clipboard entry \(index)",
                hint: "the history holds \(all.count) entries, numbered from 1")
        }
        return (all[index - 1], all)
    }

    static func json(_ entry: ClipboardEntry, index: Int) -> JSONValue {
        .object([
            "index": .int(index),
            "id": .string(entry.id),
            "kind": .string(entry.ext),
            "family": .string(entry.kind.rawValue),
            "isText": .bool(entry.isTextual),
            "preview": .optional(entry.preview),
            "sourceApp": .optional(entry.sourceApp),
            "sizeBytes": .int(entry.size),
            "pinned": .bool(entry.pinned),
            "copiedAt": .date(entry.lastCopiedAt),
        ])
    }

    static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func repin(
        _ pinned: Bool, index: Int, json: Bool
    ) async throws {
        try await execute {
            let found = try ClipboardBridge.entry(at: index)
            let outcome = try ClipboardActions.setPinned(pinned, ids: [found.entry.id])
            AppBridge.post(IPC.Name.clipboardChanged)
            let verb = pinned ? "pinned" : "unpinned"
            guard !json else {
                CLIOut.json(
                    .object([
                        "index": .int(index),
                        "id": .string(found.entry.id),
                        "pinned": .bool(pinned),
                        "changed": .bool(outcome.changed > 0),
                    ]))
                return
            }
            guard outcome.changed > 0 else {
                CLIOut.note("entry \(index) was already \(verb)")
                return
            }
            CLIOut.out("\(verb) entry \(index)")
        }
    }

    static func text(_ entry: ClipboardEntry) throws -> String {
        guard let data = ClipboardRepository.blobData(for: entry) else {
            throw CLIFailure.notFound(
                "the stored copy of that entry is gone",
                hint: "run `ed clipboard ls` to see what is still there")
        }
        guard let text = ClipboardRepository.plainText(for: entry, data: data) else {
            throw CLIFailure(
                "entry \(entry.ext) is not text",
                hint: "use `ed clipboard copy` to put it back on the pasteboard instead")
        }
        return text
    }
}

struct ClipboardListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List the clipboard history, newest first.",
        aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Only pinned entries.")
    var pinned = false

    @Option(help: "Only entries whose preview or source app contains this text.")
    var search: String?

    @Option(help: "Show at most this many entries. Pass 0 for all of them.")
    var limit: Int = 25

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            let all = ClipboardBridge.entries()
            var numbered = Array(all.enumerated().map { (index: $0 + 1, entry: $1) })
            if let search, !ClipboardActions.normalized(search).isEmpty {
                let needle = ClipboardActions.normalized(search)
                numbered = numbered.filter { ClipboardActions.matches($0.entry, query: needle) }
            }
            if pinned { numbered = numbered.filter { $0.entry.pinned } }
            let shown = limit == 0 ? numbered : Array(numbered.prefix(limit))
            guard !json else {
                CLIOut.json(
                    .array(shown.map { ClipboardBridge.json($0.entry, index: $0.index) }))
                return
            }
            let rows = shown.map { row in
                [
                    String(row.index), row.entry.ext, row.entry.pinned ? "pinned" : "",
                    ClipboardBridge.bytes(row.entry.size), row.entry.sourceApp ?? "",
                    row.entry.preview ?? "",
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["#", "KIND", "", "SIZE", "FROM", "PREVIEW"], rows: rows))
            guard shown.count < numbered.count else { return }
            CLIOut.note(
                "showing \(shown.count) of \(numbered.count); pass --limit 0 for all of them")
        }
    }
}

struct ClipboardStatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "How many entries the history holds and what they weigh.",
        aliases: ["size"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let stats = ClipboardActions.stats()
            guard !json else {
                CLIOut.json(
                    .object([
                        "count": .int(stats.count),
                        "pinned": .int(stats.pinned),
                        "sizeBytes": .int(stats.bytes),
                        "diskBytes": .int(stats.diskBytes),
                        "largestBytes": .int(stats.largest),
                        "oldest": .date(stats.oldest),
                        "newest": .date(stats.newest),
                        "byKind": .array(
                            stats.byKind.map { total in
                                .object([
                                    "kind": .string(total.kind.rawValue),
                                    "count": .int(total.count),
                                    "sizeBytes": .int(total.bytes),
                                ])
                            }),
                    ]))
                return
            }
            guard stats.count > 0 else {
                CLIOut.note("the clipboard history is empty")
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["ITEMS", "PINNED", "SIZE", "ON DISK", "LARGEST", "OLDEST"],
                    rows: [
                        [
                            String(stats.count), String(stats.pinned),
                            ClipboardBridge.bytes(stats.bytes),
                            ClipboardBridge.bytes(stats.diskBytes),
                            ClipboardBridge.bytes(stats.largest),
                            stats.oldest.map(JSONSerializer.iso.string(from:)) ?? "",
                        ]
                    ]))
            CLIOut.out("")
            CLIOut.out(
                TextTable.render(
                    headers: ["KIND", "COUNT", "SIZE"],
                    rows: stats.byKind.map {
                        [$0.kind.rawValue, String($0.count), ClipboardBridge.bytes($0.bytes)]
                    }))
        }
    }
}

struct ClipboardPinCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pin", abstract: "Keep one entry at the top and out of the retention sweep.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The entry number, counting from 1.")
    var index: Int

    func run() async throws {
        try await ClipboardBridge.repin(true, index: index, json: json)
    }
}

struct ClipboardUnpinCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unpin", abstract: "Let one entry age out again.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The entry number, counting from 1.")
    var index: Int

    func run() async throws {
        try await ClipboardBridge.repin(false, index: index, json: json)
    }
}

struct ClipboardGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Print one entry as text.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The entry number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let found = try ClipboardBridge.entry(at: index)
            let text = try ClipboardBridge.text(found.entry)
            guard !json else {
                guard case var .object(fields) = ClipboardBridge.json(found.entry, index: index)
                else { return }
                fields["text"] = .string(text)
                CLIOut.json(.object(fields))
                return
            }
            CLIOut.out(text)
        }
    }
}

struct ClipboardCopyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy", abstract: "Put one entry back on the pasteboard.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Copy as plain text even when the entry is styled.")
    var plain = false

    @Argument(help: "The entry number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let found = try ClipboardBridge.entry(at: index)
            do {
                try ClipboardActions.copy(
                    found.entry, asPlainText: plain,
                    pasteboard: CLIEnvironment.clipboardPasteboard)
            } catch ClipboardActionError.blobMissing {
                throw CLIFailure.notFound("the stored copy of that entry is gone")
            }
            AppBridge.post(IPC.Name.clipboardChanged)
            guard !json else {
                CLIOut.json(ClipboardBridge.json(found.entry, index: index))
                return
            }
            CLIOut.out("copied entry \(index)")
        }
    }
}

struct ClipboardRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Forget one entry.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The entry number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let found = try ClipboardBridge.entry(at: index)
            let outcome = try ClipboardActions.delete(ids: [found.entry.id])
            AppBridge.post(IPC.Name.clipboardChanged)
            guard !json else {
                CLIOut.json(
                    .object([
                        "removed": .int(index), "remaining": .int(outcome.entries.count),
                    ]))
                return
            }
            CLIOut.out("removed entry \(index), \(outcome.entries.count) left")
        }
    }
}

struct ClipboardClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Forget the whole history.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Keep pinned entries.")
    var keepPinned = false

    func run() async throws {
        try await execute {
            let outcome = try ClipboardActions.clear(keepingPinned: keepPinned)
            AppBridge.post(IPC.Name.clipboardChanged)
            guard !json else {
                CLIOut.json(
                    .object([
                        "removed": .int(outcome.changed),
                        "remaining": .int(outcome.entries.count),
                    ]))
                return
            }
            CLIOut.out("cleared \(outcome.changed) entries")
        }
    }
}

struct ColorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "color",
        abstract: "The colours picked with Edith's colour picker.",
        subcommands: [ColorListCommand.self, ColorClearCommand.self],
        defaultSubcommand: ColorListCommand.self,
        aliases: ["colour"])
}

struct ColorListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List picked colours, newest first.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Print each colour in one format: hex, rgb, hsl, swiftUI or nsColor.")
    var format: String?

    @Option(help: "Show at most this many colours.")
    var limit: Int = 25

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            var chosen: ColorCopyFormat?
            if let format {
                guard let value = ColorCopyFormat(rawValue: format) else {
                    throw CLIFailure.notFound(
                        "no colour format named \(format)",
                        hint: "formats: "
                            + ColorCopyFormat.allCases.map(\.rawValue).joined(separator: ", "))
                }
                chosen = value
            }
            let stored = ColorHistoryStore.load(from: CLIEnvironment.sharedDefaults)
            let swatches = limit == 0 ? stored : Array(stored.prefix(limit))
            guard !json else {
                CLIOut.json(
                    .array(
                        swatches.map { swatch in
                            .object([
                                "hex": .string(swatch.string(for: .hex)),
                                "rgb": .string(swatch.string(for: .rgb)),
                                "hsl": .string(swatch.string(for: .hsl)),
                                "profile": .string(swatch.profile.rawValue),
                                "pickedAt": .date(swatch.pickedAt),
                            ])
                        }))
                return
            }
            if let chosen {
                for swatch in swatches { CLIOut.out(swatch.string(for: chosen)) }
                return
            }
            guard !swatches.isEmpty else {
                CLIOut.note("no colours picked yet")
                return
            }
            let rows = swatches.map { swatch in
                [
                    swatch.string(for: .hex), swatch.string(for: .rgb),
                    swatch.profile.displayName,
                    JSONSerializer.iso.string(from: swatch.pickedAt),
                ]
            }
            CLIOut.out(
                TextTable.render(headers: ["HEX", "RGB", "PROFILE", "PICKED"], rows: rows))
        }
    }
}

struct ColorClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Forget every picked colour.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let count = ColorHistoryStore.load(from: CLIEnvironment.sharedDefaults).count
            ColorHistoryStore.clear(in: CLIEnvironment.sharedDefaults)
            ConfigStore.announceChange()
            guard !json else {
                CLIOut.json(.object(["removed": .int(count)]))
                return
            }
            CLIOut.out("cleared \(count) colours")
        }
    }
}
