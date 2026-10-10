import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

enum HerdrLaunchCLI {
    static func boolean(_ raw: String) throws -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes", "on", "enabled": return true
        case "0", "false", "no", "off", "disabled": return false
        default: throw ConfigurationError("\(raw) is not a boolean, use true or false")
        }
    }
    static func kind(_ query: String) throws -> AgentLaunchKind {
        guard let kind = AgentLaunchKind(kind: query) else {
            throw CLIFailure.notFound(
                "\(query) has no launch options",
                hint: "kinds: " + AgentLaunchKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return kind
    }

    static func machine(_ query: String?) throws -> Machine? {
        guard let query, !query.isEmpty, !HerdrCLI.localQueries.contains(query.lowercased())
        else { return nil }
        return try MachineResolver.machine(query)
    }

    static func effortsJSON(_ efforts: [AgentLaunchEffort]) -> JSONValue {
        .array(efforts.map { .object(["id": .string($0.id), "summary": .string($0.summary)]) })
    }

    static func modelJSON(_ model: AgentLaunchModel) -> JSONValue {
        .object([
            "id": .string(model.id),
            "name": .string(model.name),
            "summary": .string(model.summary),
            "efforts": effortsJSON(model.efforts),
            "defaultEffort": .optional(model.defaultEffort),
            "fast": .bool(model.supportsFast),
            "fastSummary": .optional(model.fastSummary),
        ])
    }

    static func catalogJSON(_ catalog: AgentLaunchCatalog) -> JSONValue {
        .object([
            "kind": .string(catalog.kind.rawValue),
            "source": .string(catalog.source.label),
            "live": .bool(catalog.source.isLive),
            "selectsAtLaunch": .bool(catalog.kind.selectsAtLaunch),
            "note": .optional(catalog.kind.note),
            "defaultEfforts": effortsJSON(catalog.standard.efforts),
            "defaultFast": .optional(catalog.standard.fastSummary),
            "models": .array(catalog.models.map(modelJSON)),
        ])
    }

    static func defaultsJSON(_ kind: AgentLaunchKind, _ options: AgentLaunchOptions) -> JSONValue {
        .object([
            "kind": .string(kind.rawValue),
            "model": .optional(options.model),
            "effort": .optional(options.effort),
            "fast": .bool(options.fast),
            "arguments": .strings(
                AgentLaunchArguments.launchArguments(kind: kind.rawValue, options: options)),
        ])
    }

    static func flags(_ kind: AgentLaunchKind, _ options: AgentLaunchOptions) -> String {
        let flags = AgentLaunchArguments.launchArguments(kind: kind.rawValue, options: options)
        return flags.isEmpty ? "-" : flags.map(ShellQuote.quote).joined(separator: " ")
    }
}

struct HerdrModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models", abstract: "List each agent's models, effort levels and fast mode.",
        discussion: """
            Lists the models, effort levels and fast mode each agent kind offers when
            Edith starts it.

            Reads the current state. Does not change it.

            ed herdr models
            ed herdr models --json
            """, )

    @Argument(help: "Agent kind, for example codex or \"Claude Code\". Every kind when omitted.")
    var kind: String?

    @Option(help: "Ask the CLIs on this machine, or local for this Mac.")
    var machine: String?

    @Flag(help: "Ask the CLI again instead of reusing a cached list.")
    var refresh = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let kinds = try kind.map { [try HerdrLaunchCLI.kind($0)] } ?? AgentLaunchKind.allCases
            let target = try HerdrLaunchCLI.machine(machine)
            var catalogs: [AgentLaunchCatalog] = []
            for kind in kinds {
                catalogs.append(
                    await AgentLaunchCatalogs.shared.catalog(
                        for: kind, on: target, refresh: refresh))
            }
            guard !json else {
                CLIOut.json(.object(["kinds": .array(catalogs.map(HerdrLaunchCLI.catalogJSON))]))
                return
            }
            for catalog in catalogs {
                CLIOut.out("\(catalog.kind.rawValue) (\(catalog.source.label))")
                if let note = catalog.kind.note { CLIOut.out(note) }
                let rows = [catalog.standard] + catalog.models
                CLIOut.out(
                    TextTable.render(
                        headers: ["MODEL", "EFFORT", "FAST", "ABOUT"],
                        rows: rows.map { model in
                            [
                                model.id.isEmpty ? "(default)" : model.id,
                                model.efforts.map(\.id).joined(separator: ","),
                                model.fastSummary ?? "-", model.summary,
                            ]
                        }))
            }
        }
    }
}

struct HerdrDefaultsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "defaults",
        abstract: "Show the model, effort and fast mode Edith passes when it starts an agent.",
        discussion: """
            The model, effort and fast mode Edith passes whenever it starts an agent of
            a given kind.

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed herdr defaults ls
            """,
        subcommands: [HerdrDefaultsListCommand.self, HerdrDefaultsSetCommand.self],
        defaultSubcommand: HerdrDefaultsListCommand.self)
}

struct HerdrDefaultsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Show the launch defaults for every agent kind.",
        discussion: """
            Show the launch defaults for every agent kind.

            Reads the saved records in stored order. Does not change them.

            ed herdr defaults ls
            ed herdr defaults ls --json
            """,
        aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let entries = AgentLaunchKind.allCases.map {
                (
                    $0,
                    HerdrLaunchSettings.options(for: $0.rawValue, in: CLIEnvironment.sharedDefaults)
                )
            }
            guard !json else {
                CLIOut.json(
                    .object(["defaults": .array(entries.map(HerdrLaunchCLI.defaultsJSON))]))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["KIND", "MODEL", "EFFORT", "FAST", "FLAGS"],
                    rows: entries.map { kind, options in
                        [
                            kind.rawValue, options.model ?? "-", options.effort ?? "-",
                            options.fast ? "on" : "off", HerdrLaunchCLI.flags(kind, options),
                        ]
                    }))
        }
    }
}

struct HerdrDefaultsSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Choose the model, effort and fast mode for an agent kind.",
        discussion: """
            Choose the model, effort and fast mode for an agent kind.

            Changes the saved setting to the value you pass.

            ed herdr defaults set kind
            ed herdr defaults set kind --json
            """, )

    @Argument(help: "Agent kind, for example codex or \"Claude Code\".")
    var kind: String

    @Option(help: "Model id or alias, or none to let the CLI choose.")
    var model: String?

    @Option(help: "Effort or thinking level, or none to let the CLI choose.")
    var effort: String?

    @Option(help: "Fast mode, on or off.")
    var fast: String?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let launchKind = try HerdrLaunchCLI.kind(kind)
            guard model != nil || effort != nil || fast != nil else {
                throw CLIFailure.usage(
                    "nothing to set", hint: "pass --model, --effort or --fast")
            }
            let fastMode: Bool?
            do {
                fastMode = try fast.map(HerdrLaunchCLI.boolean)
            } catch let error as ConfigurationError {
                throw CLIFailure.usage(error.message, hint: "use --fast on or --fast off")
            }
            let catalog = await AgentLaunchCatalogs.shared.catalog(for: launchKind)
            let options: AgentLaunchOptions
            do {
                options = try HerdrLaunchDefaults.set(
                    launchKind, model: model, effort: effort, fast: fastMode, catalog: catalog,
                    in: CLIEnvironment.sharedDefaults)
            } catch let error as AgentLaunchOptionsError {
                throw CLIFailure.usage(
                    error.errorDescription ?? "invalid launch options",
                    hint: "run `ed herdr models \(ShellQuote.quote(launchKind.rawValue))`")
            }
            guard !json else {
                CLIOut.json(HerdrLaunchCLI.defaultsJSON(launchKind, options))
                return
            }
            CLIOut.out(
                "\(launchKind.rawValue) launches with \(HerdrLaunchCLI.flags(launchKind, options))")
        }
    }
}
