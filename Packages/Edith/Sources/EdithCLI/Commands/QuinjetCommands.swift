import ArgumentParser
import EdithKit
import Foundation

struct QuinjetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quinjet",
        abstract: "Discover and open Quinjet review workspaces.",
        subcommands: [
            QuinjetProjectsCommand.self, QuinjetWorktreesCommand.self,
            QuinjetOpenCommand.self, QuinjetLaunchCommand.self,
        ],
        defaultSubcommand: QuinjetProjectsCommand.self)
}

struct QuinjetTargetOptions: ParsableArguments {
    @Option(name: .long, help: "Target a configured machine, or `local` for this Mac.")
    var machine: String?
}

struct QuinjetLaunchOptions: ParsableArguments {
    @Option(help: "Quinjet theme name.")
    var theme: String?

    @Option(help: "Choose `light` or `dark`.")
    var appearance: String?

    @Flag(name: .long, help: "Open the session in cmux.")
    var cmux = false

    @Flag(name: .long, help: "Open the session in the current terminal.")
    var embedded = false

    func configuration() throws -> QuinjetLaunchConfiguration {
        guard !(cmux && embedded) else {
            throw CLIFailure.usage("--cmux and --embedded cannot be used together")
        }
        let preferred = QuinjetLaunchConfiguration.preferred(
            sharedDefaults: CLIEnvironment.sharedDefaults,
            standardDefaults: CLIEnvironment.standardDefaults)
        let themeName = theme ?? preferred.theme.rawValue
        guard let theme = QuinjetTheme(rawValue: themeName) else {
            throw CLIFailure.usage(
                "unknown Quinjet theme \(themeName)",
                hint: "themes: " + QuinjetTheme.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let appearanceName = appearance ?? preferred.appearance.rawValue
        guard let appearance = QuinjetAppearance(rawValue: appearanceName) else {
            throw CLIFailure.usage(
                "unknown Quinjet appearance \(appearanceName)", hint: "choose light or dark")
        }
        let terminal = cmux ? QuinjetTerminal.cmux : embedded ? .embedded : preferred.terminal
        return QuinjetLaunchConfiguration(
            terminal: terminal, theme: theme, appearance: appearance)
    }
}

struct QuinjetProjectsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "projects", abstract: QuinjetOperation.projects.descriptor.summary)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @OptionGroup var target: QuinjetTargetOptions

    func run() async throws {
        try await execute {
            let target = try await QuinjetCLIEnvironment.resolveTarget(target.machine)
            let projects = try await QuinjetCLI.resolved {
                try await QuinjetOperationExecution.projects(
                    remote: target.remote, using: QuinjetCLIEnvironment.client())
            }
            QuinjetCLI.renderProjects(projects, target: target, json: json)
        }
    }
}

struct QuinjetWorktreesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worktrees", abstract: QuinjetOperation.worktrees.descriptor.summary)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @OptionGroup var target: QuinjetTargetOptions

    @Argument(help: "Project or worktree path.")
    var path: String

    func run() async throws {
        try await execute {
            let target = try await QuinjetCLIEnvironment.resolveTarget(target.machine)
            let worktrees = try await QuinjetCLI.resolved {
                try await QuinjetOperationExecution.worktrees(
                    at: path, remote: target.remote, using: QuinjetCLIEnvironment.client())
            }
            QuinjetCLI.renderWorktrees(worktrees, target: target, json: json)
        }
    }
}

struct QuinjetOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: QuinjetOperation.open.descriptor.summary)

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @OptionGroup var target: QuinjetTargetOptions
    @OptionGroup var launch: QuinjetLaunchOptions

    @Argument(help: "Project or worktree path.")
    var path: String

    func run() async throws {
        try await execute {
            let plan = try await QuinjetCLI.plan(
                path: path, machine: target.machine, launch: launch)
            QuinjetCLI.renderPlan(plan, launched: false, json: json)
        }
    }
}

struct QuinjetLaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch", abstract: QuinjetOperation.launch.descriptor.summary)

    @OptionGroup var target: QuinjetTargetOptions
    @OptionGroup var launch: QuinjetLaunchOptions

    @Flag(name: .long, help: "Emit stable JSON on stdout.")
    var json = false

    @Argument(help: "Project or worktree path.")
    var path: String

    func run() async throws {
        try await execute {
            let plan = try await QuinjetCLI.plan(
                path: path, machine: target.machine, launch: launch)
            let status = try await QuinjetCLIEnvironment.launch(plan.request, json)
            guard status == 0 else { throw ExitCode(status) }
            if json {
                QuinjetCLI.renderPlan(plan, launched: true, json: true)
            } else if plan.request.terminal == .cmux {
                CLIOut.out("Opened \(plan.selection.worktree.displayName) in cmux.")
            }
        }
    }
}

struct QuinjetCommandTarget: Sendable {
    let name: String
    let local: Bool
    let remote: QuinjetRemote?
    let connection: SSHConnection?

    static func resolve(_ query: String?) async throws -> QuinjetCommandTarget {
        if query == nil || ["local", "this-mac", "thismac"].contains(query?.lowercased() ?? "") {
            return QuinjetCommandTarget(name: "This Mac", local: true, remote: nil, connection: nil)
        }
        let machine = try MachineResolver.machine(query ?? "")
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        do {
            try await connection.connect()
        } catch {
            throw CLIFailure.unavailable(
                "could not reach \(machine.name): \(error.localizedDescription)",
                hint: "check the machine is awake and reachable, then retry")
        }
        return QuinjetCommandTarget(
            name: machine.name, local: false,
            remote: QuinjetRemote(
                machineID: machine.id, machineName: machine.name, target: machine.sshTarget,
                controlPath: connection.controlSocketPath),
            connection: connection)
    }
}

struct QuinjetCLIPlan: Sendable {
    let target: QuinjetCommandTarget
    let selection: QuinjetOpenSelection
    let request: QuinjetLaunchRequest
}

enum QuinjetCLIEnvironment {
    typealias Launcher = @Sendable (QuinjetLaunchRequest, Bool) async throws -> Int32

    nonisolated(unsafe) static var client: @Sendable () -> QuinjetClient = { .live }
    nonisolated(unsafe) static var cmuxExecutable: @Sendable () -> URL? = {
        QuinjetCMUX.executable()
    }
    nonisolated(unsafe) static var resolveTarget:
        @Sendable (String?) async throws -> QuinjetCommandTarget = {
            try await QuinjetCommandTarget.resolve($0)
        }
    nonisolated(unsafe) static var launch: Launcher = { request, noninteractive in
        try await launchLive(request, noninteractive: noninteractive)
    }

    static func reset() {
        client = { .live }
        cmuxExecutable = { QuinjetCMUX.executable() }
        resolveTarget = { try await QuinjetCommandTarget.resolve($0) }
        launch = { try await launchLive($0, noninteractive: $1) }
    }

    private static func launchLive(
        _ request: QuinjetLaunchRequest, noninteractive: Bool
    ) async throws -> Int32 {
        if request.terminal == .cmux {
            guard cmuxExecutable() != nil else {
                throw CLIFailure.unavailable(
                    "cmux is not installed in Applications",
                    hint: "install cmux, or omit --cmux to launch in this terminal")
            }
            do {
                _ = try CLIEnvironment.runAppleScript(
                    QuinjetCMUX.launchScript(request: request), 15)
                return 0
            } catch {
                throw CLIFailure.unavailable(
                    "cmux could not open Quinjet", hint: error.localizedDescription)
            }
        }
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = CLIToolEnvironment.sanitized()
        process.standardInput = noninteractive ? FileHandle.nullDevice : FileHandle.standardInput
        process.standardOutput =
            noninteractive ? CLIOut.stderrHandle : FileHandle.standardOutput
        process.standardError = noninteractive ? CLIOut.stderrHandle : FileHandle.standardError
        if let currentDirectory = request.currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        do {
            try process.run()
        } catch {
            throw CLIFailure.unavailable(
                "Quinjet could not start", hint: error.localizedDescription)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

enum QuinjetCLI {
    static func plan(
        path: String, machine: String?, launch: QuinjetLaunchOptions
    ) async throws -> QuinjetCLIPlan {
        let configuration = try launch.configuration()
        let target = try await QuinjetCLIEnvironment.resolveTarget(machine)
        let selection = try await resolved {
            try await QuinjetOperationExecution.openSelection(
                at: path, remote: target.remote, using: QuinjetCLIEnvironment.client())
        }
        guard let executable = CLIEnvironment.executableNamed("quinjet") else {
            throw missingTool()
        }
        let request = QuinjetOperationExecution.launchRequest(
            executableURL: executable, worktreePath: selection.worktree.path,
            remote: target.remote, configuration: configuration, managedByEdith: false,
            localHomeDirectory: CLIEnvironment.homeDirectory.path)
        return QuinjetCLIPlan(target: target, selection: selection, request: request)
    }

    static func resolved<Value>(_ body: () async throws -> Value) async throws -> Value {
        do {
            return try await body()
        } catch let error as QuinjetClientError {
            switch error {
            case .notInstalled:
                throw missingTool()
            case let .launchFailed(message):
                throw CLIFailure.unavailable("Quinjet could not start", hint: message)
            case let .commandFailed(message):
                throw CLIFailure("Quinjet command failed", hint: message)
            case .invalidResponse:
                throw CLIFailure(
                    "Quinjet returned malformed JSON",
                    hint: "update Quinjet and retry the command")
            }
        } catch let error as QuinjetOperationError {
            throw CLIFailure.notFound(error.localizedDescription)
        }
    }

    static func renderProjects(
        _ projects: [QuinjetProject], target: QuinjetCommandTarget, json: Bool
    ) {
        guard !json else {
            CLIOut.json(
                .object([
                    "local": .bool(target.local), "machine": .string(target.name),
                    "projects": .array(projects.map(projectJSON)),
                ]))
            return
        }
        guard !projects.isEmpty else {
            CLIOut.note("no recent Quinjet projects on \(target.name)")
            return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["PROJECT", "WORKTREES", "PATH"],
                rows: projects.map {
                    [$0.name, String($0.availableWorktrees.count), $0.defaultWorktree?.path ?? "-"]
                }))
    }

    static func renderWorktrees(
        _ worktrees: [QuinjetWorktree], target: QuinjetCommandTarget, json: Bool
    ) {
        guard !json else {
            CLIOut.json(
                .object([
                    "local": .bool(target.local), "machine": .string(target.name),
                    "worktrees": .array(worktrees.map(worktreeJSON)),
                ]))
            return
        }
        guard !worktrees.isEmpty else {
            CLIOut.note("no worktrees found on \(target.name)")
            return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["WORKTREE", "PATH", "STATE"],
                rows: worktrees.map {
                    [
                        $0.displayName,
                        $0.path,
                        $0.canOpen ? ($0.current ? "current" : "open") : "unavailable",
                    ]
                }))
    }

    static func renderPlan(_ plan: QuinjetCLIPlan, launched: Bool, json: Bool) {
        guard !json else {
            CLIOut.json(
                .object([
                    "arguments": .strings(plan.request.arguments),
                    "command": .string(plan.request.shellCommand),
                    "currentDirectory": .optional(plan.request.currentDirectory),
                    "executable": .string(plan.request.executableURL.path),
                    "launched": .bool(launched),
                    "local": .bool(plan.target.local),
                    "machine": .string(plan.target.name),
                    "terminal": .string(plan.request.terminal == .cmux ? "cmux" : "current"),
                    "worktree": worktreeJSON(plan.selection.worktree),
                ]))
            return
        }
        CLIOut.out(plan.request.shellCommand)
    }

    private static func projectJSON(_ project: QuinjetProject) -> JSONValue {
        .object([
            "commonDir": .string(project.commonDir), "name": .string(project.name),
            "worktrees": .array(project.worktrees.map(worktreeJSON)),
        ])
    }

    private static func worktreeJSON(_ worktree: QuinjetWorktree) -> JSONValue {
        .object([
            "bare": .bool(worktree.bare), "branch": .optional(worktree.branch),
            "canOpen": .bool(worktree.canOpen), "current": .bool(worktree.current),
            "detached": .bool(worktree.detached), "displayName": .string(worktree.displayName),
            "head": .string(worktree.head), "locked": .optional(worktree.locked),
            "path": .string(worktree.path), "prunable": .optional(worktree.prunable),
        ])
    }

    private static func missingTool() -> CLIFailure {
        CLIFailure.unavailable(
            "Quinjet is not installed",
            hint: "install it with `brew install pulkitxm/tap/quinjet`")
    }
}
