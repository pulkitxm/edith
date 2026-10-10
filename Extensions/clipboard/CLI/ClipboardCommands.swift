import AppKit
import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct ClipboardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "List and restore the clipboard history Edith keeps.",
        discussion: """
            Clipboard storage is owned by the Edith daemon and remains available when
            the app is closed. Entries are numbered from 1, newest first, and that
            number is what `get`, `copy` and `rm` take.

            Reads the daemon's clipboard store. copy changes the pasteboard. pin, rm, and clear change history. ls, get, and stats do not change stored entries.

            ed clipboard ls
            ed clipboard copy 3
            """,
        subcommands: [
            ClipboardListCommand.self, ClipboardStatsCommand.self, ClipboardGetCommand.self,
            ClipboardCopyCommand.self, ClipboardPinCommand.self, ClipboardUnpinCommand.self,
            ClipboardRemoveCommand.self, ClipboardClearCommand.self,
        ],
        defaultSubcommand: ClipboardListCommand.self)
}

enum ClipboardBridge {
    static func entries(query: String = "") async throws -> [ClipboardEntry] {
        ClipboardActions.arrange(
            try await ClipboardCLIEnvironment.client.entries(), query: query,
            pinToTop: ClipboardActions.pinToTopPreference(ClipboardCLIEnvironment.defaults))
    }

    static func entry(at index: Int) async throws -> (entry: ClipboardEntry, all: [ClipboardEntry])
    {
        let all = try await entries()
        guard !all.isEmpty else {
            let recording =
                ClipboardCLIEnvironment.defaults.object(forKey: AppStorageKeys.Clipboard.enabled)
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
            "category": .string(ClipboardCategory(entry).rawValue),
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
            let found = try await ClipboardBridge.entry(at: index)
            let outcome = try await ClipboardCLIEnvironment.client.mutate(
                .init(pinned ? .pin : .unpin, ids: [found.entry.id]))
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

    static func text(_ entry: ClipboardEntry) async throws -> String {
        let payload = try await ClipboardCLIEnvironment.client.copy(
            id: entry.id, plainTextOnly: true)
        guard entry.isTextual, let text = payload.text else {
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
        discussion: """
            List clipboard history, pinned entries first, newest first.
            Reads the daemon's clipboard store. Does not change entries. --search keeps rows that mention the text.

            ed clipboard ls
            ed clipboard ls --search token --json
            """,
        aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Only pinned entries.")
    var pinned = false

    @Option(help: "Only entries whose preview or source app contains every word of this text.")
    var search: String?

    @Option(help: "Only one kind of clip: text, link, email, color, image, media or file.")
    var category: ClipboardCategory?

    @Option(help: "Show at most this many entries. Pass 0 for all of them.")
    var limit: Int = 25

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            let all = try await ClipboardBridge.entries()
            var numbered = Array(all.enumerated().map { (index: $0 + 1, entry: $1) })
            if let search, !ClipboardActions.normalized(search).isEmpty {
                let needle = ClipboardActions.normalized(search)
                numbered = numbered.filter { ClipboardActions.matches($0.entry, query: needle) }
            }
            if let category {
                numbered = numbered.filter { ClipboardCategory($0.entry) == category }
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
        abstract: "Count clipboard entries and how much they weigh.",
        discussion: """
            Count clipboard entries and how much they weigh.
            Reads the history store. Does not change it.

            ed clipboard stats
            ed clipboard stats --json
            """,
        aliases: ["size"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let stats = try await ClipboardCLIEnvironment.client.stats()
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
        commandName: "pin", abstract: "Keep one entry at the top and out of the retention sweep.",
        discussion: """
            Pin one history entry so retention will not drop it.
            Reads the entry by number. Changes that entry by pinning it. Numbers start at 1.

            ed clipboard pin 3
            ed clipboard pin 3 --json
            """)

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
        commandName: "unpin", abstract: "Let one entry age out again.",
        discussion: """
            Unpin one history entry so retention can drop it again.
            Reads the entry by number. Changes that entry by clearing the pin.

            ed clipboard unpin 3
            ed clipboard unpin 3 --json
            """)

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
        commandName: "get", abstract: "Print one entry as text.",
        discussion: """
            Print one history entry as text.
            Reads that entry. Does not change the pasteboard or the history.

            ed clipboard get 3
            ed clipboard get 3 --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The entry number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let found = try await ClipboardBridge.entry(at: index)
            let text = try await ClipboardBridge.text(found.entry)
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
        commandName: "copy", abstract: "Put one entry back on the pasteboard.",
        discussion: """
            Copy one history entry back onto the pasteboard.
            Reads that entry. Changes the system pasteboard. Does not change the history row.

            ed clipboard copy 3
            ed clipboard copy 3 --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Copy as plain text even when the entry is styled.")
    var plain = false

    @Argument(help: "The entry number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let found = try await ClipboardBridge.entry(at: index)
            let payload = try await ClipboardCLIEnvironment.client.copy(
                id: found.entry.id, plainTextOnly: plain)
            try await ClipboardCLIEnvironment.copy(payload)
            _ = try await ClipboardCLIEnvironment.client.mutate(
                .init(.copied, ids: [found.entry.id]))
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
        commandName: "rm", abstract: "Forget one entry.",
        discussion: """
            Delete one history entry.
            Reads the entry number. Without --yes, prints the plan and does not change anything. With --yes, changes the store by removing it.

            ed clipboard rm 3
            ed clipboard rm 3 --yes
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually remove it. Without this nothing is touched.")
    var yes = false

    @Argument(help: "The entry number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let found = try await ClipboardBridge.entry(at: index)
            let plan = CLIDestructivePlan(
                action: "remove clipboard entry", targets: [found.entry.id], confirmed: yes,
                json: json,
                fields: [
                    "index": .int(index),
                    "id": .string(found.entry.id),
                    "preview": .optional(found.entry.preview),
                ])
            guard plan.shouldApply() else { return }
            let outcome = try await ClipboardCLIEnvironment.client.mutate(
                .init(.delete, ids: [found.entry.id]))
            plan.finish(
                changed: outcome.changed > 0,
                plain: "removed entry \(index), \(outcome.total) left",
                fields: [
                    "removed": .int(index), "remaining": .int(outcome.total),
                ])
        }
    }
}

struct ClipboardClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Forget the whole history.",
        discussion: """
            Delete clipboard history.
            Reads how many entries exist. Without --yes, does not change anything. With --yes, changes the store. --keep-pinned leaves pinned rows.

            ed clipboard clear
            ed clipboard clear --yes --keep-pinned
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually clear it. Without this nothing is touched.")
    var yes = false

    @Flag(help: "Keep pinned entries.")
    var keepPinned = false

    func run() async throws {
        try await execute {
            let entries = try await ClipboardBridge.entries()
            let clearPlan = ClipboardOperationExecution.clearPlan(
                entries: entries, keepPinned: keepPinned)
            let plan = CLIDestructivePlan(
                action: "clear clipboard history", targets: clearPlan.targetIDs,
                confirmed: yes, json: json,
                fields: [
                    "keepPinned": .bool(keepPinned),
                    "removed": .int(clearPlan.removed),
                    "remaining": .int(clearPlan.remaining),
                ])
            guard plan.shouldApply() else { return }
            let outcome = try await ClipboardCLIEnvironment.client.mutate(
                .init(.delete, ids: clearPlan.targetIDs))
            plan.finish(
                changed: outcome.changed > 0, plain: "cleared \(outcome.changed) entries",
                fields: [
                    "removed": .int(outcome.changed),
                    "remaining": .int(outcome.total),
                ])
        }
    }
}

extension ClipboardCategory: ExpressibleByArgument {}
