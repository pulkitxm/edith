import AppKit
import ArgumentParser
import EdithKit
import Foundation

struct ClipboardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "The clipboard history Edith keeps.",
        discussion: """
            Clipboard storage is owned by the Edith daemon and remains available when
            the app is closed. Entries are numbered from 1, newest first, and that
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
    static func entries(query: String = "") async throws -> [ClipboardEntry] {
        ClipboardActions.arrange(
            try await ClipboardCLIEnvironment.client.entries(), query: query,
            pinToTop: ClipboardActions.pinToTopPreference(CLIEnvironment.sharedDefaults))
    }

    static func entry(at index: Int) async throws -> (entry: ClipboardEntry, all: [ClipboardEntry])
    {
        let all = try await entries()
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
            let all = try await ClipboardBridge.entries()
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
        commandName: "copy", abstract: "Put one entry back on the pasteboard.")

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
            await MainActor.run {
                ClipboardRepository.copyToPasteboard(
                    payload, pasteboard: CLIEnvironment.clipboardPasteboard)
            }
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
        commandName: "rm", abstract: "Forget one entry.")

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
        commandName: "clear", abstract: "Forget the whole history.")

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

struct ColorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "color",
        abstract: "The colours picked with Edith's colour picker.",
        subcommands: [
            ColorPickCommand.self, ColorListCommand.self, ColorCopyCommand.self,
            ColorClearCommand.self,
        ],
        defaultSubcommand: ColorListCommand.self,
        aliases: ["colour"])
}

enum ColorBridge {
    static func format(_ name: String) throws -> ColorCopyFormat {
        guard let format = ColorCopyFormat(rawValue: name) else {
            throw CLIFailure.notFound(
                "no colour format named \(name)",
                hint: "formats: "
                    + ColorCopyFormat.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return format
    }

    static func swatch(at index: Int) throws -> ColorSwatch {
        let history = ColorHistoryStore.load(from: CLIEnvironment.sharedDefaults)
        guard !history.isEmpty else {
            throw CLIFailure.unavailable(
                "the colour history is empty",
                hint: "run `ed color pick`, then choose a colour")
        }
        guard index >= 1, index <= history.count else {
            throw CLIFailure.notFound(
                "there is no colour \(index)",
                hint: "the history holds \(history.count) colours, numbered from 1")
        }
        return history[index - 1]
    }
}

struct ColorPickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pick", abstract: "Open Edith's system colour sampler.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard
                CLIEnvironment.sharedDefaults.object(forKey: AppStorageKeys.ColorPicker.enabled)
                    as? Bool == true
            else {
                throw CLIFailure.unavailable(
                    "the Color Picker extension is off",
                    hint: "run `ed extensions enable colorPicker`, then retry")
            }
            try AppBridge.requireHelper("picking a color")
            let descriptor = ColorPickerOperationExecution.request(.pick) {
                AppBridge.post($0)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "operation": .string(descriptor.id.rawValue),
                        "requested": .bool(true),
                    ]))
                return
            }
            CLIOut.out("color picker requested")
        }
    }
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
                chosen = try ColorBridge.format(format)
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

struct ColorCopyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy", abstract: "Copy one picked colour to the pasteboard.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Copy as hex, rgb, hsl, swiftUI or nsColor.")
    var format: String?

    @Argument(help: "The colour number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let swatch = try ColorBridge.swatch(at: index)
            let configured =
                CLIEnvironment.sharedDefaults.string(
                    forKey: AppStorageKeys.ColorPicker.copyFormat) ?? ColorCopyFormat.hex.rawValue
            let chosen =
                try format.map(ColorBridge.format)
                ?? ColorCopyFormat(rawValue: configured) ?? .hex
            let result: ColorSwatchOperationResult
            do {
                result = try ColorSwatchOperationExecution.perform(
                    .copy, swatch: swatch, format: chosen,
                    write: { value in
                        CLIEnvironment.clipboardPasteboard.clearContents()
                        return CLIEnvironment.clipboardPasteboard.setString(
                            value, forType: .string)
                    })
            } catch let error as ColorSwatchOperationError {
                throw CLIFailure.unavailable(
                    error.localizedDescription,
                    hint: "check pasteboard access, then retry")
            }
            AppBridge.post(IPC.Name.clipboardChanged)
            guard !json else {
                CLIOut.json(
                    .object([
                        "operation": .string(result.operation.descriptor.id.rawValue),
                        "index": .int(index),
                        "id": .string(result.swatchID.uuidString),
                        "format": .string(result.format.rawValue),
                        "value": .string(result.value),
                        "copied": .bool(true),
                    ]))
                return
            }
            CLIOut.out("copied colour \(index) as \(result.value)")
        }
    }
}

struct ColorClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Forget every picked colour.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually clear it. Without this nothing is touched.")
    var yes = false

    func run() async throws {
        try await execute {
            let swatches = ColorHistoryStore.load(from: CLIEnvironment.sharedDefaults)
            let plan = CLIDestructivePlan(
                action: "clear color history", targets: swatches.map { $0.id.uuidString },
                confirmed: yes, json: json, fields: ["removed": .int(swatches.count)])
            guard plan.shouldApply() else { return }
            ColorHistoryStore.clear(in: CLIEnvironment.sharedDefaults)
            ConfigStore.announceChange()
            plan.finish(
                changed: !swatches.isEmpty, plain: "cleared \(swatches.count) colours")
        }
    }
}
