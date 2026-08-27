import ArgumentParser
import EdithKit
import Foundation

struct EmojiCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "emoji",
        abstract: "The emoji picker and the emoji it knows about.",
        subcommands: [
            EmojiPickCommand.self, EmojiListCommand.self, EmojiInsertCommand.self,
            EmojiToneCommand.self, EmojiClearCommand.self,
        ],
        defaultSubcommand: EmojiListCommand.self)
}

enum EmojiBridge {
    static func requireExtension() throws {
        guard
            CLIEnvironment.sharedDefaults.object(forKey: AppStorageKeys.Emoji.enabled) as? Bool
                == true
        else {
            throw CLIFailure.unavailable(
                "the Emoji Picker extension is off",
                hint: "run `ed extensions enable emoji`, then retry")
        }
    }

    static func resolve(_ value: String) throws -> String {
        do {
            return try EmojiOperationExecution.resolve(
                value, in: .shared, store: CLIEnvironment.sharedDefaults)
        } catch {
            throw CLIFailure.notFound(
                "no emoji matches \(value)",
                hint: "run `ed emoji ls` to see what this Mac can render")
        }
    }

    static func tone(_ value: String) throws -> EmojiSkinTone {
        guard let tone = EmojiSkinTone(token: value) else {
            throw CLIFailure.notFound(
                "no skin tone named \(value)",
                hint: "tones: " + EmojiSkinTone.allCases.map(\.token).joined(separator: ", "))
        }
        return tone
    }
}

struct EmojiPickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pick", abstract: "Open Edith's emoji picker.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try EmojiBridge.requireExtension()
            try AppBridge.requireHelper("opening the emoji picker")
            let descriptor = EmojiOperationExecution.request(.pick) { name, info in
                AppBridge.post(name, userInfo: info)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "operation": .string(descriptor.id.rawValue),
                        "requested": .bool(true),
                    ]))
                return
            }
            CLIOut.out("emoji picker requested")
        }
    }
}

struct EmojiListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List the emoji this Mac can render.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "List only your frequently used emoji.")
    var frequent = false

    @Option(help: "Filter by name, keyword or shortcode.")
    var search: String?

    @Option(help: "Filter by category id, for example smileys-emotion.")
    var group: String?

    @Option(help: "Show at most this many emoji.")
    var limit: Int = 50

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            let catalog = EmojiCatalog.shared
            let matches = try select(from: catalog, limit: limit)
            guard !json else {
                CLIOut.json(
                    .array(
                        matches.map { emoji in
                            .object([
                                "emoji": .string(emoji.character),
                                "name": .string(emoji.name),
                                "group": .string(catalog.group(at: emoji.groupIndex)?.id ?? ""),
                                "unicodeVersion": .double(emoji.unicodeVersion),
                                "skinTones": .array(emoji.toneVariants.map { .string($0) }),
                                "keywords": .array(emoji.terms.map { .string($0) }),
                            ])
                        }))
                return
            }
            guard !matches.isEmpty else {
                CLIOut.note(frequent ? "no emoji used yet" : "no emoji match")
                return
            }
            for emoji in matches { CLIOut.out("\(emoji.character)  \(emoji.name)") }
        }
    }

    private func select(from catalog: EmojiCatalog, limit: Int) throws -> [Emoji] {
        var pool = catalog.emoji
        if frequent {
            let characters = EmojiCatalogSummary.frequent(
                catalog: catalog, store: CLIEnvironment.sharedDefaults)
            pool = characters.compactMap { catalog.emoji(matching: $0) }
        }
        if let group {
            guard let index = catalog.groups.firstIndex(where: { $0.id == group }) else {
                throw CLIFailure.notFound(
                    "no emoji category named \(group)",
                    hint: "categories: " + catalog.groups.map(\.id).joined(separator: ", "))
            }
            pool = pool.filter { $0.groupIndex == index }
        }
        if let search { pool = EmojiSearch.results(in: pool, query: search) }
        return limit == 0 ? pool : Array(pool.prefix(limit))
    }
}

struct EmojiInsertCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "insert", abstract: "Type an emoji into the frontmost app.")

    @Argument(help: "The emoji itself, its hexcode such as 1F600, or part of its name.")
    var emoji: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try EmojiBridge.requireExtension()
            let character = try EmojiBridge.resolve(emoji)
            try AppBridge.requireHelper("inserting an emoji")
            let descriptor = EmojiOperationExecution.request(
                .insert, userInfo: ["character": character]
            ) { name, info in
                AppBridge.post(name, userInfo: info)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "operation": .string(descriptor.id.rawValue),
                        "emoji": .string(character),
                    ]))
                return
            }
            CLIOut.out("inserted \(character)")
        }
    }
}

struct EmojiToneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tone", abstract: "Set the default skin tone for emoji that support one.")

    @Argument(help: "default, light, medium-light, medium, medium-dark or dark.")
    var tone: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let resolved = try EmojiBridge.tone(tone)
            CLIEnvironment.sharedDefaults.set(
                resolved.rawValue, forKey: AppStorageKeys.Emoji.skinTone)
            AppBridge.post(IPC.Name.settingsChanged)
            guard !json else {
                CLIOut.json(
                    .object([
                        "tone": .string(resolved.token),
                        "sample": .string(resolved.sample),
                    ]))
                return
            }
            CLIOut.out("skin tone set to \(resolved.token) \(resolved.sample)")
        }
    }
}

struct EmojiClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Forget the frequently used emoji.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            var ledger = EmojiUsageLedger.load(
                from: CLIEnvironment.sharedDefaults, key: AppStorageKeys.Emoji.usage)
            let removed = ledger.entries.count
            ledger.clear()
            ledger.save(to: CLIEnvironment.sharedDefaults, key: AppStorageKeys.Emoji.usage)
            AppBridge.post(IPC.Name.settingsChanged)
            guard !json else {
                CLIOut.json(.object(["cleared": .int(removed)]))
                return
            }
            CLIOut.out("cleared \(removed) frequently used emoji")
        }
    }
}
