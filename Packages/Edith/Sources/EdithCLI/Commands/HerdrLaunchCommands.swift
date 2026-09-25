import ArgumentParser
import EdithKit
import Foundation

enum HerdrLaunchCLI {
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
        commandName: "models", abstract: "List each agent's models, effort levels and fast mode.")

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
        abstract: "The model, effort and fast mode Edith passes when it starts an agent.",
        subcommands: [HerdrDefaultsListCommand.self, HerdrDefaultsSetCommand.self],
        defaultSubcommand: HerdrDefaultsListCommand.self)
}

struct HerdrDefaultsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Show the launch defaults for every agent kind.",
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
        commandName: "set", abstract: "Choose the model, effort and fast mode for an agent kind.")

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
                fastMode = try fast.map(ConfigurationValueParser.boolean)
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
