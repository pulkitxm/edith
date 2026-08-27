import ArgumentParser
import EdithKit
import Foundation

struct TextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text", abstract: "Expand, clean, and protect text and links.",
        subcommands: [
            TextStatusCommand.self, TextCleanURLCommand.self, TextPastePlainCommand.self,
            TextSnippetsCommand.self,
        ], defaultSubcommand: TextStatusCommand.self)
}

enum TextCLI {
    static var snippets: [TextSnippet] {
        TextUtilitiesSupport.decode(
            CLIEnvironment.sharedDefaults.string(forKey: AppStorageKeys.TextUtilities.snippets))
    }

    static func snippet(at index: Int, in snippets: [TextSnippet]) throws -> TextSnippet {
        guard index >= 1, index <= snippets.count else {
            throw CLIFailure.notFound(
                "there is no text snippet \(index)",
                hint: snippets.isEmpty
                    ? "add one with `ed text snippets add`"
                    : "snippets are numbered from 1 through \(snippets.count)")
        }
        return snippets[index - 1]
    }

    static func expansion(_ value: String) throws -> TextSnippetExpansion {
        switch value.lowercased() {
        case "immediate": .immediate
        case "delimiter", "after-delimiter": .afterDelimiter
        default:
            throw CLIFailure.usage(
                "unknown expansion mode \(value)",
                hint: "pass immediate or after-delimiter")
        }
    }

    static func save(_ snippets: [TextSnippet]) {
        CLIEnvironment.sharedDefaults.set(
            TextUtilitiesSupport.encode(snippets),
            forKey: AppStorageKeys.TextUtilities.snippets)
        AppBridge.post(IPC.Name.settingsChanged)
    }

    static func json(_ snippet: TextSnippet, index: Int) -> JSONValue {
        .object([
            "index": .int(index),
            "id": .string(snippet.id.uuidString),
            "name": .string(snippet.name),
            "trigger": .string(snippet.trigger),
            "replacement": .string(snippet.replacement),
            "folder": .string(snippet.folder),
            "expansion": .string(snippet.expansion.rawValue),
            "ignoresCase": .bool(snippet.ignoresCase),
            "enabled": .bool(snippet.enabled),
        ])
    }

    static func validated(name: String, trigger: String, replacement: String) throws -> (
        String, String, String
    ) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trigger = TextUtilitiesSupport.sanitizedTrigger(trigger)
        guard !name.isEmpty else { throw CLIFailure.usage("snippet names cannot be empty") }
        guard !trigger.isEmpty else { throw CLIFailure.usage("snippet triggers cannot be empty") }
        guard !replacement.isEmpty else {
            throw CLIFailure.usage("snippet replacements cannot be empty")
        }
        return (name, trigger, replacement)
    }
}

struct TextStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show Text Utilities settings and saved snippet count.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let defaults = CLIEnvironment.sharedDefaults
            let fields: [String: JSONValue] = [
                "enabled": .bool(defaults.bool(forKey: AppStorageKeys.TextUtilities.enabled)),
                "snippetsEnabled": .bool(
                    defaults.object(forKey: AppStorageKeys.TextUtilities.snippetsEnabled) as? Bool
                        ?? true),
                "snippetCount": .int(TextCLI.snippets.count),
                "cleanCopiedURLs": .bool(
                    defaults.bool(forKey: AppStorageKeys.TextUtilities.cleanCopiedURLs)),
                "autoClearEnabled": .bool(
                    defaults.bool(forKey: AppStorageKeys.TextUtilities.autoClearEnabled)),
                "autoClearDelay": .int(
                    TextUtilitiesSupport.clampedAutoClearDelay(
                        defaults.object(forKey: AppStorageKeys.TextUtilities.autoClearDelay) as? Int
                            ?? TextUtilitiesSupport.defaultAutoClearDelay)),
                "clearOnLock": .bool(
                    defaults.bool(forKey: AppStorageKeys.TextUtilities.clearOnLock)),
                "clearOnSleep": .bool(
                    defaults.bool(forKey: AppStorageKeys.TextUtilities.clearOnSleep)),
                "shortcut": .string(
                    defaults.string(forKey: AppStorageKeys.TextUtilities.hotKeyLabel) ?? "⌃⌥⌘V"),
            ]
            guard !json else {
                CLIOut.json(.object(fields))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["EXTENSION", "SNIPPETS", "CLEAN URLS", "AUTO CLEAR", "SHORTCUT"],
                    rows: [[
                        defaults.bool(forKey: AppStorageKeys.TextUtilities.enabled) ? "on" : "off",
                        String(TextCLI.snippets.count),
                        defaults.bool(forKey: AppStorageKeys.TextUtilities.cleanCopiedURLs)
                            ? "on" : "off",
                        defaults.bool(forKey: AppStorageKeys.TextUtilities.autoClearEnabled)
                            ? "on" : "off",
                        defaults.string(forKey: AppStorageKeys.TextUtilities.hotKeyLabel) ?? "⌃⌥⌘V",
                    ]]))
        }
    }
}

struct TextCleanURLCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean-url", abstract: "Remove known tracking parameters from a URL.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(
        name: .long,
        help: "Additional comma-separated parameter names to remove.")
    var parameters: String?

    @Argument(help: "The complete http or https URL to clean.")
    var value: String

    func run() async throws {
        try await execute {
            let configured = CLIEnvironment.sharedDefaults.string(
                forKey: AppStorageKeys.TextUtilities.customTrackingParameters) ?? ""
            let custom = TextUtilitiesSupport.customParameters(parameters ?? configured)
            guard let result = TextUtilitiesSupport.cleanURL(value, customParameters: custom) else {
                throw CLIFailure.usage(
                    "the value is not a complete http or https URL",
                    hint: "pass a URL such as https://example.com/?utm_source=mail")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "url": .string(result.value),
                        "removed": .strings(result.removedParameters),
                        "changed": .bool(result.value != value),
                    ]))
                return
            }
            CLIOut.out(result.value)
        }
    }
}

struct TextPastePlainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paste-plain",
        abstract: "Paste the current clipboard text without formatting.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard CLIEnvironment.sharedDefaults.bool(
                forKey: AppStorageKeys.TextUtilities.enabled)
            else {
                throw CLIFailure.unavailable(
                    "the Text Utilities extension is off",
                    hint: "run `ed extensions enable textUtilities`")
            }
            try AppBridge.requireHelper("plain-text paste")
            AppBridge.post(IPC.Name.requestPlainTextPaste)
            if json {
                CLIOut.json(.object(["requested": .bool(true), "operation": .string("text.paste-plain")]))
            } else {
                CLIOut.out("requested plain-text paste")
            }
        }
    }
}

struct TextSnippetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snippets", abstract: "Manage saved text expansions.",
        subcommands: [
            TextSnippetListCommand.self, TextSnippetAddCommand.self, TextSnippetSetCommand.self,
            TextSnippetRemoveCommand.self,
        ], defaultSubcommand: TextSnippetListCommand.self)
}

struct TextSnippetListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List text snippets.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Only snippets in this folder.")
    var folder: String?

    @Option(help: "Match name, trigger, replacement, or folder.")
    var search: String?

    func run() async throws {
        try await execute {
            let all = TextCLI.snippets
            let rows = all.enumerated().filter { _, snippet in
                let folderMatches = folder.map { snippet.folder == $0 } ?? true
                let queryMatches = search.map {
                    TextUtilitiesSupport.sections([snippet], query: $0).isEmpty == false
                } ?? true
                return folderMatches && queryMatches
            }
            guard !json else {
                CLIOut.json(.array(rows.map { TextCLI.json($0.element, index: $0.offset + 1) }))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["#", "NAME", "TRIGGER", "FOLDER", "MODE", "ENABLED"],
                    rows: rows.map {
                        [
                            String($0.offset + 1), $0.element.name, $0.element.trigger,
                            $0.element.folder, $0.element.expansion.rawValue,
                            $0.element.enabled ? "yes" : "no",
                        ]
                    }))
        }
    }
}

struct TextSnippetAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Add a text snippet.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Human-readable snippet name.")
    var name: String?

    @Option(help: "Folder shown in settings.")
    var folder = ""

    @Option(help: "immediate or after-delimiter.")
    var mode = "after-delimiter"

    @Flag(name: .long, help: "Match the trigger without letter case.")
    var ignoreCase = false

    @Flag(name: .long, help: "Save the snippet turned off.")
    var disabled = false

    @Argument(help: "The typed trigger.")
    var trigger: String

    @Argument(help: "The replacement text.")
    var replacement: String

    func run() async throws {
        try await execute {
            let values = try TextCLI.validated(
                name: name ?? trigger, trigger: trigger, replacement: replacement)
            let snippet = TextSnippet(
                name: values.0, trigger: values.1, replacement: values.2,
                folder: TextUtilitiesSupport.sanitizedFolder(folder),
                expansion: try TextCLI.expansion(mode), ignoresCase: ignoreCase,
                enabled: !disabled)
            var snippets = TextCLI.snippets
            guard !snippets.contains(where: { $0.trigger == snippet.trigger }) else {
                throw CLIFailure.usage(
                    "the trigger \(snippet.trigger) already exists",
                    hint: "change it with `ed text snippets set`")
            }
            snippets.append(snippet)
            TextCLI.save(snippets)
            if json {
                CLIOut.json(TextCLI.json(snippet, index: snippets.count))
            } else {
                CLIOut.out("added snippet \(snippets.count): \(snippet.name)")
            }
        }
    }
}

struct TextSnippetSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Change a text snippet.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option var name: String?
    @Option var trigger: String?
    @Option var replacement: String?
    @Option var folder: String?
    @Option(help: "immediate or after-delimiter.") var mode: String?
    @Option(help: "Whether trigger matching ignores letter case.") var ignoreCase: Bool?
    @Option(help: "Whether the snippet can expand.") var enabled: Bool?

    @Argument(help: "The snippet number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            guard [name, trigger, replacement, folder, mode].contains(where: { $0 != nil })
                || ignoreCase != nil || enabled != nil
            else {
                throw CLIFailure.usage("pass at least one value to change")
            }
            var snippets = TextCLI.snippets
            var snippet = try TextCLI.snippet(at: index, in: snippets)
            let values = try TextCLI.validated(
                name: name ?? snippet.name, trigger: trigger ?? snippet.trigger,
                replacement: replacement ?? snippet.replacement)
            snippet.name = values.0
            snippet.trigger = values.1
            snippet.replacement = values.2
            if let folder { snippet.folder = TextUtilitiesSupport.sanitizedFolder(folder) }
            if let mode { snippet.expansion = try TextCLI.expansion(mode) }
            if let ignoreCase { snippet.ignoresCase = ignoreCase }
            if let enabled { snippet.enabled = enabled }
            guard !snippets.enumerated().contains(where: {
                $0.offset != index - 1 && $0.element.trigger == snippet.trigger
            }) else {
                throw CLIFailure.usage("the trigger \(snippet.trigger) already exists")
            }
            snippets[index - 1] = snippet
            TextCLI.save(snippets)
            if json {
                CLIOut.json(TextCLI.json(snippet, index: index))
            } else {
                CLIOut.out("updated snippet \(index): \(snippet.name)")
            }
        }
    }
}

struct TextSnippetRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Remove a text snippet.", aliases: ["remove"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Apply the removal.")
    var yes = false

    @Argument(help: "The snippet number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            var snippets = TextCLI.snippets
            let snippet = try TextCLI.snippet(at: index, in: snippets)
            let plan = CLIDestructivePlan(
                action: "remove text snippet", targets: ["\(index): \(snippet.name)"],
                confirmed: yes, json: json,
                fields: ["index": .int(index), "id": .string(snippet.id.uuidString)])
            guard plan.shouldApply() else { return }
            snippets.remove(at: index - 1)
            TextCLI.save(snippets)
            plan.finish(changed: true, plain: "removed snippet \(index): \(snippet.name)")
        }
    }
}
