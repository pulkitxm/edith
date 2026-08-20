import ArgumentParser
import EdithKit
import Foundation

public let edithCLIVersion = "1.0.0"

func execute(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let failure as CLIFailure {
        CLIOut.report(failure)
        throw ExitCode(failure.kind.rawValue)
    } catch let exit as ExitCode {
        throw exit
    } catch {
        CLIOut.note("error: " + error.localizedDescription)
        throw ExitCode(1)
    }
}

public struct EdRoot: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ed",
        abstract: "The command line for Edith.",
        discussion: """
            `ed <machine> <command...>` runs a command on a configured machine.
            `ed guide` prints the full manual, written for agents and humans alike.
            """,
        version: edithCLIVersion,
        subcommands: [
            GuideCommand.self,
            SchemaCommand.self,
            VersionCommand.self,
            CompletionsCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
            ConfigCommand.self,
            AppCommand.self,
            ExtensionsCommand.self,
            LidAwakeCLICommand.self,
            PermissionsCommand.self,
            UsageCommand.self,
            SystemCommand.self,
            MusicCommand.self,
            CalendarCommand.self,
            HerdrCommand.self,
            ClipboardCommand.self,
            DownloadCommand.self,
            AppsCommand.self,
            ToolsCommand.self,
            ColorCommand.self,
            ShelfCommand.self,
            CleanerCommand.self,
            MachinesCommand.self,
            CompanionCommand.self,
            CompleteCommand.self,
        ])

    public init() {}
}

public enum ExitCodes {
    public static let success: Int32 = 0
    public static let failure: Int32 = 1
    public static let usage: Int32 = 2
    public static let notFound: Int32 = 3
    public static let unavailable: Int32 = 4

    public static func report(_ error: Error) {
        if let failure = error as? CLIFailure {
            CLIOut.report(failure)
            return
        }
        if error is ExitCode { return }
        let message = EdRoot.fullMessage(for: error)
        guard !message.isEmpty else { return }
        guard EdRoot.exitCode(for: error) == .success else {
            CLIOut.note(message)
            return
        }
        CLIOut.out(EdRoot.message(for: error))
    }

    public static func code(for error: Error) -> Int32 {
        if let exit = error as? ExitCode { return exit.rawValue }
        if let failure = error as? CLIFailure { return failure.kind.rawValue }
        let resolved = EdRoot.exitCode(for: error).rawValue
        return resolved == ExitCode.validationFailure.rawValue ? usage : resolved
    }
}

public enum EdithCLIMain {
    public static func run() async {
        let raw = Array(CommandLine.arguments.dropFirst())
        let machines = MachineDirectory.names(from: MachineDirectory.load())
        let arguments = ArgumentRewriting.rewrite(raw, machines: machines)
        do {
            var command = try EdRoot.parseAsRoot(arguments)
            if var runnable = command as? AsyncParsableCommand {
                try await runnable.run()
            } else {
                try command.run()
            }
        } catch {
            ExitCodes.report(error)
            exit(ExitCodes.code(for: error))
        }
    }
}

struct GuideCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guide",
        abstract: "Print the built-in manual, written for agents and humans alike.")

    @Argument(help: "Pass `claude` for a CLAUDE.md snippet that makes a repo ed-aware.")
    var topic: String?

    func run() async throws {
        try await execute {
            switch topic?.lowercased() {
            case nil:
                CLIOut.out(Guide.text)
            case "claude":
                CLIOut.out(Guide.claudeSnippet)
            case let other?:
                throw CLIFailure.notFound(
                    "no guide topic named \(other)", hint: "try `ed guide` or `ed guide claude`")
            }
        }
    }
}

struct SchemaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema",
        abstract: "Print the JSON Schema for the configuration document.")

    func run() async throws {
        CLIOut.json(ConfigSchema.document())
    }
}

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version", abstract: "Print the Edith CLI version.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        guard !json else {
            CLIOut.json(
                .object([
                    "version": .string(edithCLIVersion),
                    "appRunning": .bool(AppBridge.helperIsRunning),
                ]))
            return
        }
        CLIOut.out(edithCLIVersion)
    }
}

struct CompletionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completions",
        abstract: "Generate a shell completion script.",
        subcommands: [
            CompletionsZshCommand.self, CompletionsBashCommand.self,
            CompletionsFishCommand.self, CompletionsInstallCommand.self,
        ],
        defaultSubcommand: CompletionsInstallCommand.self)
}

struct CompletionsZshCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zsh", abstract: "Print the zsh completion script.")

    func run() async throws {
        try await execute { CLIOut.out(CompletionScripts.script(for: .zsh)) }
    }
}

struct CompletionsBashCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bash", abstract: "Print the bash completion script.")

    func run() async throws {
        try await execute { CLIOut.out(CompletionScripts.script(for: .bash)) }
    }
}

struct CompletionsFishCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fish", abstract: "Print the fish completion script.")

    func run() async throws {
        try await execute { CLIOut.out(CompletionScripts.script(for: .fish)) }
    }
}

struct CompletionsInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Write completion scripts for the shells found on this Mac.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Install for one shell instead of every detected shell.")
    var shell: String?

    func run() async throws {
        try await execute {
            let shells: [CompletionScripts.Shell]
            if let shell {
                guard let value = CompletionScripts.Shell(rawValue: shell.lowercased()) else {
                    throw CLIFailure.notFound("\(shell) is not a supported shell")
                }
                shells = [value]
            } else {
                shells = CompletionScripts.detectShells()
            }
            var installed: [JSONValue] = []
            for value in shells {
                let file = try CompletionScripts.install(value)
                let directory = file.deletingLastPathComponent()
                installed.append(
                    .object([
                        "shell": .string(value.rawValue),
                        "path": .string(file.path),
                        "hint": .optional(
                            CompletionScripts.rcHint(for: value, directory: directory)),
                    ]))
            }
            guard !json else {
                CLIOut.json(.object(["installed": .array(installed)]))
                return
            }
            for entry in installed {
                guard case let .object(fields) = entry,
                    case let .string(shell)? = fields["shell"],
                    case let .string(path)? = fields["path"]
                else { continue }
                CLIOut.out("\(shell): \(path)")
                if case let .string(hint)? = fields["hint"] { CLIOut.out("  \(hint)") }
            }
        }
    }
}

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Link ed, edh and edith into a directory on PATH.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Install into this directory instead of the default.")
    var directory: String?

    func run() async throws {
        try await execute {
            let target = directory.map {
                URL(fileURLWithPath: $0.expandingTilde())
            }
            let result = CLIInstaller.install(into: target)
            let onPath = CLIInstaller.isOnPath(
                URL(fileURLWithPath: result.directory), entries: CLIInstaller.pathEntries())
            guard !json else {
                CLIOut.json(
                    .object([
                        "directory": .string(result.directory),
                        "linked": .strings(result.linked),
                        "skipped": .strings(result.skipped),
                        "onPath": .bool(onPath),
                        "message": .optional(result.message),
                    ]))
                return
            }
            if let message = result.message {
                throw CLIFailure(message)
            }
            CLIOut.out("linked \(result.linked.joined(separator: ", ")) in \(result.directory)")
            if !onPath {
                CLIOut.note("note: \(result.directory) is not on PATH")
            }
        }
    }
}

struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Remove the ed, edh and edith links.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        let result = CLIInstaller.uninstall()
        guard !json else {
            CLIOut.json(
                .object([
                    "directory": .string(result.directory),
                    "removed": .strings(result.linked),
                ]))
            return
        }
        CLIOut.out(
            result.linked.isEmpty
                ? "nothing to remove in \(result.directory)"
                : "removed \(result.linked.joined(separator: ", ")) from \(result.directory)")
    }
}

struct CompleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__complete", abstract: "Emit completion candidates.", shouldDisplay: false)

    @Option(help: "Zero based index of the word being completed.")
    var index: Int = 0

    @Argument(parsing: .captureForPassthrough)
    var words: [String] = []

    func run() async throws {
        let machines = MachineDirectory.load()
        let request = CompletionRequest(
            words: CompletionRequest.stripSeparator(words), index: index)
        let result = CompletionEngine.plan(
            request, machines: MachineDirectory.names(from: machines),
            configKeys: ConfigCatalog.keys,
            extensionIDs: ExtensionRegistry.entries.map(\.id))
        if let name = result.remoteMachine,
            let machine = try? MachineDirectory.resolve(
                name, in: machines)
        {
            for candidate in await RemoteCompletion.candidates(machine: machine, request: request) {
                CLIOut.out(candidate)
            }
            return
        }
        for line in result.lines { CLIOut.out(line) }
    }
}
