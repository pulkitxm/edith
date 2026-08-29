import ArgumentParser
import EdithCore
import EdithKit
import Foundation

struct AutomationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "automations", abstract: "Run local automations and reusable scenes.",
        subcommands: [
            AutomationOperationsCommand.self, AutomationListCommand.self,
            AutomationPlanCommand.self, AutomationRunCommand.self,
            AutomationEnableCommand.self, AutomationDisableCommand.self,
            AutomationHistoryCommand.self, AutomationExportCommand.self,
            AutomationImportCommand.self,
        ], defaultSubcommand: AutomationListCommand.self)
}

enum AutomationCLI {
    static var storage: AutomationStorage {
        let root =
            ProcessInfo.processInfo.environment["EDITH_AUTOMATIONS_ROOT"]
            .map(URL.init(fileURLWithPath:)) ?? AppDirectories.current.data
        return AutomationStorage(root: root)
    }

    static func document() throws -> AutomationDocument {
        try storage.load()
    }

    static func scene(_ query: String, in document: AutomationDocument) throws -> AutomationScene {
        let lowered = query.lowercased()
        guard
            let scene = document.scenes.first(where: {
                $0.id.uuidString.lowercased() == lowered || $0.name.lowercased() == lowered
            })
        else {
            throw CLIFailure.notFound(
                "no scene matches \(query)", hint: "run `ed automations ls` to list scenes")
        }
        return scene
    }

    static func itemIndex(
        _ query: String, in document: AutomationDocument
    ) throws -> (scene: Int?, automation: Int?) {
        let lowered = query.lowercased()
        let scene = document.scenes.firstIndex {
            $0.id.uuidString.lowercased() == lowered || $0.name.lowercased() == lowered
        }
        let automation = document.automations.firstIndex {
            $0.id.uuidString.lowercased() == lowered || $0.name.lowercased() == lowered
        }
        guard scene != nil || automation != nil else {
            throw CLIFailure.notFound(
                "no automation or scene matches \(query)",
                hint: "run `ed automations ls` to list configured items")
        }
        return (scene, automation)
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        CLIOut.out(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func grantedPermissions() -> Set<AutomationPermission> {
        let statuses = Dictionary(
            uniqueKeysWithValues: CLIEnvironment.permissionUsages().map {
                ($0.permission.rawValue, $0.isGranted)
            })
        return Set(AutomationPermission.allCases.filter { statuses[$0.rawValue] == true })
    }
}

struct AutomationOperationsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "operations", abstract: "List operations available to scene steps.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() throws {
        let operations = UserOperationCatalog.descriptors.filter {
            !$0.id.rawValue.hasPrefix("automations.")
        }
        if json {
            CLIOut.json(
                .array(
                    operations.map {
                        .object([
                            "id": .string($0.id.rawValue), "summary": .string($0.summary),
                            "cli": .array($0.cli.map(JSONValue.string)),
                            "effect": .string($0.effect.rawValue),
                            "requiresPreview": .bool($0.requiresPreview),
                            "permissions": .array($0.requiredPermissions.map(JSONValue.string)),
                        ])
                    }))
            return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["OPERATION", "EFFECT", "SUMMARY"],
                rows: operations.map { [$0.id.rawValue, $0.effect.rawValue, $0.summary] }))
    }
}

struct AutomationListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List automations and scenes.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() throws {
        let document = try AutomationCLI.document()
        if json { try AutomationCLI.printJSON(document); return }
        let scenes = document.scenes.map {
            ["scene", $0.name, $0.isEnabled ? "enabled" : "disabled", "\($0.actions.count) steps"]
        }
        let automations = document.automations.map {
            [
                "automation", $0.name, $0.isEnabled ? "enabled" : "disabled",
                $0.trigger.kind.rawValue,
            ]
        }
        let rows = scenes + automations
        guard !rows.isEmpty else { CLIOut.note("no automations or scenes configured"); return }
        CLIOut.out(TextTable.render(headers: ["TYPE", "NAME", "STATE", "DETAIL"], rows: rows))
    }
}

struct AutomationPlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan", abstract: "Preview a scene execution plan.")

    @Argument(help: "Scene name or id.") var scene: String
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() throws {
        let scene = try AutomationCLI.scene(scene, in: AutomationCLI.document())
        let plan = AutomationPlanner.plan(
            scene: scene, grantedPermissions: AutomationCLI.grantedPermissions())
        if json {
            CLIOut.json(
                .object([
                    "scene": .string(plan.sceneName), "runnable": .bool(plan.isRunnable),
                    "confirmationRequired": .bool(plan.requiresConfirmation),
                    "errors": .array(plan.errors.map(JSONValue.string)),
                    "steps": .array(
                        plan.steps.map {
                            .object([
                                "operation": .string($0.operationID),
                                "command": .array($0.command.map(JSONValue.string)),
                                "effect": .string($0.effect.rawValue),
                                "timeoutSeconds": .double($0.timeoutSeconds),
                                "missingPermissions": .array(
                                    $0.missingPermissions.map { .string($0.rawValue) }),
                            ])
                        }),
                ]))
            return
        }
        CLIOut.out("scene: \(plan.sceneName)")
        for (index, step) in plan.steps.enumerated() {
            CLIOut.out("\(index + 1). \(step.command.joined(separator: " "))")
        }
        for error in plan.errors { CLIOut.note("error: \(error)") }
        for step in plan.steps {
            for permission in step.missingPermissions {
                CLIOut.note("permission: \(step.operationID) needs \(permission.rawValue)")
            }
        }
    }
}

struct AutomationRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Run a reusable scene.")

    @Argument(help: "Scene name or id.") var scene: String
    @Flag(name: .long, help: "Preview without running.") var dryRun = false
    @Flag(name: .long, help: "Approve previewed or destructive steps.") var yes = false
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let scene = try AutomationCLI.scene(scene, in: AutomationCLI.document())
            let permissions = AutomationCLI.grantedPermissions()
            let plan = AutomationPlanner.plan(scene: scene, grantedPermissions: permissions)
            guard plan.isRunnable else {
                throw CLIFailure.unavailable(
                    (plan.errors
                        + plan.steps.flatMap { step in
                            step.missingPermissions.map {
                                "\(step.operationID) needs \($0.rawValue) permission"
                            }
                        }).joined(separator: "; "))
            }
            if dryRun {
                if json {
                    CLIOut.json(
                        .object([
                            "scene": .string(scene.name), "dryRun": .bool(true),
                            "steps": .array(
                                plan.steps.map {
                                    .array($0.command.map(JSONValue.string))
                                }),
                        ]))
                } else {
                    for step in plan.steps { CLIOut.out(step.command.joined(separator: " ")) }
                }
                return
            }
            if plan.requiresConfirmation, !yes {
                throw CLIFailure.usage(
                    "scene \(scene.name) contains previewed or destructive steps",
                    hint: "inspect `ed automations plan \(scene.name)`, then rerun with --yes")
            }
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let executor = AutomationExecutor(
                runner: {
                    try await AutomationCommandProcess.run(executable: executable, arguments: $0)
                },
                storage: AutomationCLI.storage)
            let runID = try await executor.start(
                scene: scene, origin: .commandLine, grantedPermissions: permissions)
            guard let record = await executor.wait(for: runID) else {
                throw CLIFailure("the scene result was not available")
            }
            if json { try AutomationCLI.printJSON(record); return }
            for step in record.steps {
                CLIOut.out("\(step.state.rawValue)  \(step.operationID)  \(step.output)")
            }
            if !record.succeeded { throw ExitCode.failure }
        }
    }
}

private struct AutomationToggleCommand {
    let enabled: Bool
    let query: String
    let json: Bool

    func run() throws {
        var document = try AutomationCLI.document()
        let index = try AutomationCLI.itemIndex(query, in: document)
        if let scene = index.scene { document.scenes[scene].isEnabled = enabled }
        if let automation = index.automation {
            document.automations[automation].isEnabled = enabled
        }
        try AutomationCLI.storage.save(document)
        AppBridge.post(IPC.Name.settingsChanged)
        if json {
            CLIOut.json(.object(["name": .string(query), "enabled": .bool(enabled)]))
        } else {
            CLIOut.out("\(query) \(enabled ? "enabled" : "disabled")")
        }
    }
}

struct AutomationEnableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable", abstract: "Enable an automation or scene.")
    @Argument(help: "Automation or scene name or id.") var name: String
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    func run() throws { try AutomationToggleCommand(enabled: true, query: name, json: json).run() }
}

struct AutomationDisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable", abstract: "Disable an automation or scene.")
    @Argument(help: "Automation or scene name or id.") var name: String
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    func run() throws { try AutomationToggleCommand(enabled: false, query: name, json: json).run() }
}

struct AutomationHistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history", abstract: "Show recent automation results.")
    @Option(name: .long, help: "Show at most this many runs.") var limit = 20
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    func run() throws {
        let records = Array(try AutomationCLI.storage.history().suffix(max(0, limit)).reversed())
        if json { try AutomationCLI.printJSON(records); return }
        CLIOut.out(
            TextTable.render(
                headers: ["WHEN", "SCENE", "RESULT"],
                rows: records.map {
                    [$0.startedAt.formatted(), $0.sceneName, $0.succeeded ? "succeeded" : "failed"]
                }))
    }
}

struct AutomationExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Export automations and scenes.")
    @Argument(help: "Destination JSON path.") var path: String
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    func run() throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        try AutomationCLI.storage.export(to: url)
        if json { CLIOut.json(.object(["path": .string(url.path)])) } else { CLIOut.out(url.path) }
    }
}

struct AutomationImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import", abstract: "Import automations and scenes.")
    @Argument(help: "Source JSON path.") var path: String
    @Flag(name: .long, help: "Validate without saving.") var dryRun = false
    @Flag(name: .long, help: "Approve replacing local automation configuration.") var yes = false
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    func run() throws {
        guard dryRun || yes else {
            throw CLIFailure.usage(
                "import replaces local automation configuration",
                hint: "run with --dry-run to inspect it or --yes to apply it")
        }
        let document = try AutomationCLI.storage.importDocument(
            from: URL(fileURLWithPath: path).standardizedFileURL, dryRun: dryRun)
        if !dryRun { AppBridge.post(IPC.Name.settingsChanged) }
        if json {
            try AutomationCLI.printJSON(document)
        } else {
            CLIOut.out("\(document.automations.count) automations, \(document.scenes.count) scenes")
        }
    }
}
