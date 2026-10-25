import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read and write every setting the Edith UI exposes.",
        discussion: """
            Read and write the same defaults the settings UI uses.
            Reads the catalog and current values. set and unset change the live app. ls, get, and describe do not change anything.

            ed config ls --group presenter
            ed config set preventSleep true
            """,
        subcommands: [
            ConfigListCommand.self, ConfigGetCommand.self, ConfigSetCommand.self,
            ConfigUnsetCommand.self, ConfigDescribeCommand.self, ConfigExportCommand.self,
            ConfigImportCommand.self,
        ],
        defaultSubcommand: ConfigListCommand.self)
}

private func definition(_ key: String) throws -> SettingDefinition {
    guard let found = ConfigCatalog.definition(for: key) else {
        let near = ConfigCatalog.keys.filter { $0.lowercased().contains(key.lowercased()) }
        throw CLIFailure.notFound(
            "no setting named \(key)",
            hint: near.isEmpty
                ? "run `ed config ls` to see every key"
                : "did you mean: " + near.prefix(5).joined(separator: ", "))
    }
    return found
}

private func text(_ value: JSONValue) -> String {
    switch value {
    case .null: return ""
    case let .string(text): return text
    default: return JSONSerializer.string(value, pretty: false)
    }
}

struct ConfigListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List settings and their current values.",
        discussion: """
            List catalog settings and the value each one has now.
            Reads the defaults suite. Does not change settings. --group limits the list. --changed keeps only keys you have set.

            ed config ls
            ed config ls --group machines --json
            """,
        aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Only settings in this group.")
    var group: String?

    @Flag(help: "Only settings that differ from their default.")
    var changed = false

    @Argument(help: "Only settings whose key starts with this prefix.")
    var prefix: String?

    func run() async throws {
        try await execute {
            let store = ConfigStore()
            var settings = ConfigCatalog.matching(prefix: prefix ?? "")
            if let prefix, !prefix.isEmpty, settings.isEmpty {
                let siblings = ConfigCommand.configuration.subcommands
                    .compactMap { $0.configuration.commandName }
                guard !siblings.contains(prefix) else {
                    throw CLIFailure.usage("\(prefix) is a subcommand, not a setting prefix")
                }
                let near = siblings.filter { $0.hasPrefix(String(prefix.prefix(2))) }
                throw CLIFailure.notFound(
                    "no setting starts with \(prefix)",
                    hint: near.isEmpty
                        ? "run `ed config ls` to see every key"
                        : "did you mean `ed config " + near.joined(separator: "` or `ed config ")
                            + "`?")
            }
            if let group {
                guard ConfigCatalog.groups.contains(group) else {
                    throw CLIFailure.notFound(
                        "no group named \(group)",
                        hint: "groups: " + ConfigCatalog.groups.joined(separator: ", "))
                }
                settings = settings.filter { $0.group == group }
            }
            if changed {
                settings = settings.filter { store.isSet($0) }
            }
            guard !json else {
                CLIOut.json(.array(settings.map { store.describe($0) }))
                return
            }
            let rows = settings.map { definition in
                [
                    definition.key, definition.group, definition.type.rawValue,
                    text(store.value(for: definition)),
                ]
            }
            CLIOut.out(TextTable.render(headers: ["KEY", "GROUP", "TYPE", "VALUE"], rows: rows))
        }
    }
}

struct ConfigGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Print one setting.",
        discussion: """
            Print the current value of one catalog key.
            Reads that key from the defaults suite. Does not change it.

            ed config get preventSleep
            ed config get preventSleep --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The setting key.")
    var key: String

    func run() async throws {
        try await execute {
            let found = try definition(key)
            let store = ConfigStore()
            guard !json else {
                CLIOut.json(store.describe(found))
                return
            }
            CLIOut.out(text(store.value(for: found)))
        }
    }
}

struct ConfigSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Write one setting, live, to the running app.",
        discussion: """
            Validate one catalog value and write it.
            Reads the catalog to reject an unknown key or a bad value. Changes the live setting. The running app picks it up without a restart.

            ed config set warnPercent 70
            ed config set preventSleep true --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The setting key.")
    var key: String

    @Argument(help: "The new value.")
    var value: String

    func run() async throws {
        try await execute {
            let found = try definition(key)
            let store = ConfigStore()
            let previous = store.value(for: found)
            let parsed = try ConfigValueParser.parse(
                value, as: found.type, allowed: found.allowed)
            try store.set(parsed, for: found, announce: true)
            guard !json else {
                CLIOut.json(
                    .object([
                        "key": .string(found.key),
                        "previous": previous,
                        "value": store.value(for: found),
                    ]))
                return
            }
            CLIOut.out("\(found.key) = \(text(store.value(for: found)))")
        }
    }
}

struct ConfigUnsetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unset", abstract: "Restore one setting to its default.",
        discussion: """
            Remove the stored value so the catalog default applies again.
            Reads the catalog default. Changes the stored value by deleting it.

            ed config unset preventSleep
            ed config unset preventSleep --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The setting key.")
    var key: String

    func run() async throws {
        try await execute {
            let found = try definition(key)
            let store = ConfigStore()
            try store.unset(found, announce: true)
            guard !json else {
                CLIOut.json(
                    .object(["key": .string(found.key), "value": store.value(for: found)]))
                return
            }
            CLIOut.out("\(found.key) = \(text(store.value(for: found)))")
        }
    }
}

struct ConfigDescribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe", abstract: "Explain one setting.",
        discussion: """
            Explain one catalog key: type, scope, and allowed values.
            Reads the catalog. Does not change the setting.

            ed config describe preventSleep
            ed config describe preventSleep --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The setting key.")
    var key: String

    func run() async throws {
        try await execute {
            let found = try definition(key)
            let store = ConfigStore()
            guard !json else {
                CLIOut.json(store.describe(found))
                return
            }
            CLIOut.out(found.key)
            CLIOut.out("  " + found.summary)
            CLIOut.out("  type     \(found.type.rawValue)")
            CLIOut.out("  group    \(found.group)")
            CLIOut.out("  scope    \(found.scope.rawValue)")
            if !found.allowed.isEmpty {
                CLIOut.out("  allowed  " + found.allowed.joined(separator: ", "))
            }
            if let range = found.integerRange {
                CLIOut.out("  range    \(range.lowerBound)...\(range.upperBound)")
            }
            CLIOut.out("  default  " + text(found.fallback))
            CLIOut.out("  value    " + text(store.value(for: found)))
            if found.readOnly { CLIOut.out("  read only") }
        }
    }
}

struct ConfigExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Print the settings you have changed as one JSON document.",
        discussion: """
            The document is exactly what `ed config import` accepts and what `ed schema`
            describes. Only settings with a stored value are included, so importing it
            elsewhere changes nothing you never touched. Pass --defaults to include
            every writable setting at its current effective value.

            Reads stored settings. Does not change them.

            ed config export
            ed config export --defaults
            """)

    @Flag(name: .long, help: "Include settings still at their default.")
    var defaults = false

    func run() async throws {
        let store = ConfigStore()
        let settings = ConfigCatalog.settings.filter { definition in
            guard !definition.readOnly, definition.type != .map else { return false }
            return defaults || store.isSet(definition)
        }
        CLIOut.json(store.snapshot(settings))
    }
}

struct ConfigImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import", abstract: "Apply a JSON document of settings.",
        discussion: """
            Apply a settings document that ed schema describes.
            Reads the JSON file and the catalog. Changes stored settings. --dry-run prints the plan and does not change anything.

            ed config import edith.json --dry-run
            ed config import edith.json --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .customLong("dry-run"), help: "Report what would change without writing.")
    var dryRun = false

    @Argument(help: "Path to a JSON file, or - for stdin.")
    var file: String

    func run() async throws {
        try await execute {
            let data: Data
            if file == "-" {
                data = ExtensionCLIContext.request?.standardInput ?? Data()
            } else {
                guard
                    let contents = try? Data(
                        contentsOf: ExtensionCLIContext.resolvePath(file))
                else {
                    throw CLIFailure.notFound("could not read \(file)")
                }
                data = contents
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw CLIFailure("\(file) is not a JSON object of settings")
            }
            let store = ConfigStore()
            var applied: [String] = []
            var skipped: [String] = []
            var unchanged: [String] = []
            var pending: [(SettingDefinition, JSONValue)] = []
            for key in object.keys.sorted() {
                guard let found = ConfigCatalog.definition(for: key), !found.readOnly else {
                    skipped.append(key)
                    continue
                }
                guard let raw = object[key], let value = try? coerce(raw, to: found) else {
                    skipped.append(key)
                    continue
                }
                guard value != store.value(for: found) else {
                    unchanged.append(key)
                    continue
                }
                pending.append((found, value))
                applied.append(key)
            }
            if !dryRun {
                for (definition, value) in pending {
                    try store.set(value, for: definition, announce: false)
                }
            }
            if !dryRun, !applied.isEmpty { ConfigStore.announceChange() }
            guard !json else {
                CLIOut.json(
                    .object([
                        "applied": .strings(applied),
                        "unchanged": .strings(unchanged),
                        "skipped": .strings(skipped),
                        "dryRun": .bool(dryRun),
                    ]))
                return
            }
            let noun = applied.count == 1 ? "setting" : "settings"
            CLIOut.out("\(dryRun ? "would apply" : "applied") \(applied.count) \(noun)")
            if !unchanged.isEmpty {
                CLIOut.note("\(unchanged.count) already matched")
            }
            if !skipped.isEmpty {
                CLIOut.note("skipped: " + skipped.joined(separator: ", "))
            }
        }
    }

    private func coerce(_ raw: Any, to definition: SettingDefinition) throws -> JSONValue {
        do {
            return try ConfigurationValueParser.coerce(raw, to: definition)
        } catch let error as ConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }
}
