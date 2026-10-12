import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct EmojiCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "emoji",
        abstract: "Open the emoji picker and list the emoji this Mac can render.",
        discussion: """
            Open the emoji picker and list the emoji this Mac can render.
            Reads the emoji catalog and the saved skin tone. pick opens UI. tone and clear change preferences. ls does not change anything.

            ed emoji ls --search rocket
            ed emoji insert 1F600
            """,
        subcommands: [
            EmojiPickCommand.self, EmojiListCommand.self, EmojiInsertCommand.self,
            EmojiToneCommand.self, EmojiForgetCommand.self, EmojiClearCommand.self,
        ],
        defaultSubcommand: EmojiListCommand.self)
}

@MainActor enum EmojiBridge {
    static func requireExtension() throws {
        guard
            EmojiCLIEnvironment.defaults.object(forKey: AppStorageKeys.Emoji.enabled) as? Bool
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
                value, in: EmojiCLIEnvironment.catalog, store: EmojiCLIEnvironment.defaults)
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
        commandName: "pick", abstract: "Open Edith's emoji picker.",
        discussion: """
            Open Edith's emoji picker on the desktop.
            Reads nothing from the catalog until the picker does. Changes focus by opening the picker. Needs the running app.

            ed emoji pick
            ed emoji pick --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            try EmojiBridge.requireExtension()
            EmojiCLIEnvironment.pick()
            let descriptor = EmojiOperation.pick.descriptor
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
        commandName: "ls", abstract: "List the emoji this Mac can render.",
        discussion: """
            List emoji this Mac can render, optionally filtered with --search.
            Reads the emoji catalog. Does not change frequently used emoji.

            ed emoji ls --search rocket
            ed emoji ls --json
            """, aliases: ["list"])

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

    @MainActor func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            let catalog = EmojiCLIEnvironment.catalog
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

    @MainActor private func select(from catalog: EmojiCatalog, limit: Int) throws -> [Emoji] {
        var pool = catalog.emoji
        if frequent {
            let characters = EmojiCatalogSummary.frequent(
                catalog: catalog, store: EmojiCLIEnvironment.defaults)
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
        commandName: "insert", abstract: "Type an emoji into the frontmost app.",
        discussion: """
            Type one emoji into the frontmost app.
            Reads the code point. Changes the frontmost app's text by inserting the character. Needs the running app.

            ed emoji insert 1F600
            ed emoji insert 1F600 --json
            """)

    @Argument(help: "The emoji itself, its hexcode such as 1F600, or part of its name.")
    var emoji: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            try EmojiBridge.requireExtension()
            let character = try EmojiBridge.resolve(emoji)
            let descriptor = EmojiOperation.insert.descriptor
            guard try await EmojiCLIEnvironment.insert(character) else {
                throw CLIFailure.unavailable(
                    "Edith could not insert the emoji into the frontmost app",
                    hint: "grant Accessibility with `ed permissions request accessibility`")
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
        commandName: "tone", abstract: "Set the default skin tone for emoji that support one.",
        discussion: """
            Set the default skin tone used for emoji that support one.
            Reads the tone name. Changes the stored default tone.

            ed emoji tone medium
            ed emoji tone medium --json
            """)

    @Argument(help: "default, light, medium-light, medium, medium-dark or dark.")
    var tone: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            let resolved = try EmojiBridge.tone(tone)
            EmojiCLIEnvironment.defaults.set(
                resolved.rawValue, forKey: AppStorageKeys.Emoji.skinTone)
            EmojiCLIEnvironment.changed()
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

struct EmojiForgetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forget",
        abstract: "Forget one frequently used emoji.",
        discussion: """
            Writes the frequently used ledger without that character. The rest stay.
            Example: `ed emoji forget 1F600`.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Emoji character, name, or code point.")
    var emoji: String

    @MainActor func run() async throws {
        try await execute {
            let character = try EmojiBridge.resolve(emoji)
            var ledger = EmojiUsageLedger.load(
                from: EmojiCLIEnvironment.defaults, key: AppStorageKeys.Emoji.usage)
            let before = ledger.entries.count
            ledger.forget(character)
            let removed = before - ledger.entries.count
            ledger.save(to: EmojiCLIEnvironment.defaults, key: AppStorageKeys.Emoji.usage)
            EmojiCLIEnvironment.changed()
            guard !json else {
                CLIOut.json(
                    .object(["character": .string(character), "removed": .bool(removed > 0)]))
                return
            }
            CLIOut.out(removed > 0 ? "forgot \(character)" : "\(character) was not in the ledger")
        }
    }
}

struct EmojiClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Forget the frequently used emoji.",
        discussion: """
            Forget every frequently used emoji.
            Reads the frequent list. Changes it by clearing every entry.

            ed emoji clear
            ed emoji clear --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            var ledger = EmojiUsageLedger.load(
                from: EmojiCLIEnvironment.defaults, key: AppStorageKeys.Emoji.usage)
            let removed = ledger.entries.count
            ledger.clear()
            ledger.save(to: EmojiCLIEnvironment.defaults, key: AppStorageKeys.Emoji.usage)
            EmojiCLIEnvironment.changed()
            guard !json else {
                CLIOut.json(.object(["cleared": .int(removed)]))
                return
            }
            CLIOut.out("cleared \(removed) frequently used emoji")
        }
    }
}
