import ArgumentParser
import EdithKit
import Foundation

public let edithCLIVersion = EdithCLIVersion.resolve(Bundle.main.infoDictionary)

enum EdithCLIVersion {
    static func resolve(_ infoDictionary: [String: Any]?) -> String {
        guard
            let value = infoDictionary?["CFBundleShortVersionString"] as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "development" }
        return value
    }
}

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
            StatusCommand.self,
            CompletionsCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
            ConfigCommand.self,
            AppCommand.self,
            ExtensionsCommand.self,
            AutomationsCommand.self,
            LidAwakeCLICommand.self,
            PermissionsCommand.self,
            UsageCommand.self,
            SystemCommand.self,
            MusicCommand.self,
            CalendarCommand.self,
            PresenterCommand.self,
            HerdrCommand.self,
            ClipboardCommand.self,
            AttentionCommand.self,
            DownloadCommand.self,
            AppsCommand.self,
            ToolsCommand.self,
            ColorCommand.self,
            EmojiCommand.self,
            ShelfCommand.self,
            CleanerCommand.self,
            QuinjetCommand.self,
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

enum MachineDirectoryCache {
    nonisolated(unsafe) private static var loaded: [Machine]?

    static func machines() -> [Machine] {
        if let loaded { return loaded }
        let machines = MachineDirectory.load()
        loaded = machines
        return machines
    }
}

public enum EdithCLIMain {
    public static func run() async {
        let raw = Array(CommandLine.arguments.dropFirst())
        let arguments = rewritten(raw)
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

    static func rewritten(_ raw: [String]) -> [String] {
        guard let first = raw.first, !first.hasPrefix("-") else { return raw }
        if first == ArgumentRewriting.machinesGroup {
            return ArgumentRewriting.rewrite(raw, machines: [])
        }
        guard !ArgumentRewriting.reserved.contains(first) else { return raw }
        return ArgumentRewriting.rewrite(
            raw, machines: MachineDirectory.names(from: MachineDirectoryCache.machines()))
    }
}

struct GuideCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guide",
        abstract: "Print the built-in manual, written for agents and humans alike.")

    @Flag(name: .long, help: "Emit the complete command and argument catalog as JSON.")
    var json = false

    @Argument(help: "Pass `agent` for a repository instruction snippet.")
    var topic: String?

    func run() async throws {
        try await execute {
            if json {
                guard topic == nil else {
                    throw CLIFailure.usage(
                        "--json does not take a guide topic",
                        hint: "run `ed guide --json` for the command catalog")
                }
                let source = Data(EdRoot._dumpHelp().utf8)
                let catalog = try JSONSerialization.jsonObject(with: source)
                let encoded = try JSONSerialization.data(
                    withJSONObject: catalog,
                    options: [.sortedKeys])
                CLIOut.out(String(decoding: encoded, as: UTF8.self))
                return
            }
            switch topic?.lowercased() {
            case nil:
                CLIOut.out(Guide.text)
            case "agent":
                CLIOut.out(Guide.agentSnippet)
            case let other?:
                throw CLIFailure.notFound(
                    "no guide topic named \(other)",
                    hint: "try `ed guide`, `ed guide agent`, or `ed guide --json`")
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

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Inspect command-line tools and shell completions.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let status = TerminalToolingOperationExecution.status()
            guard !json else {
                CLIOut.json(
                    .object([
                        "tools": toolStatusJSON(status.tools),
                        "completions": .array(status.completions.map(completionStatusJSON)),
                        "fallbackSource": .string(status.fallbackSourceLine),
                    ]))
                return
            }
            let linked =
                status.tools.linked.isEmpty
                ? "none" : status.tools.linked.joined(separator: ", ")
            CLIOut.out("tools: \(linked)")
            CLIOut.out("directory: \(status.tools.directory)")
            CLIOut.out("on PATH: \(status.tools.onPath ? "yes" : "no")")
            for completion in status.completions {
                CLIOut.out(
                    "\(completion.shell.rawValue): \(completion.state.rawValue) \(completion.path.path)"
                )
            }
            CLIOut.out("fallback: \(status.fallbackSourceLine)")
        }
    }
}

struct CompletionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completions",
        abstract: "Generate a shell completion script.",
        subcommands: [
            CompletionsZshCommand.self, CompletionsBashCommand.self,
            CompletionsFishCommand.self, CompletionsInstallCommand.self,
            CompletionsSourceCommand.self,
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

struct CompletionsSourceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "source",
        abstract: "Print the fallback line that loads a completion script.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Print the line for this shell.")
    var shell = "zsh"

    func run() async throws {
        try await execute {
            guard let selected = CompletionScripts.Shell(rawValue: shell.lowercased()) else {
                throw CLIFailure.notFound("\(shell) is not a supported shell")
            }
            let line = TerminalToolingOperationExecution.fallbackSource(for: selected)
            guard !json else {
                CLIOut.json(
                    .object([
                        "shell": .string(selected.rawValue), "source": .string(line),
                    ]))
                return
            }
            CLIOut.out(line)
        }
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
            let outcome = TerminalToolingOperationExecution.installCompletions(shells: shells)
            guard !json else {
                CLIOut.json(completionInstallJSON(outcome))
                if !outcome.succeeded { throw ExitCode.failure }
                return
            }
            for installed in outcome.installed {
                CLIOut.out("\(installed.shell.rawValue): \(installed.path.path)")
                if let hint = installed.hint { CLIOut.out("  \(hint)") }
            }
            for failure in outcome.failures {
                CLIOut.note("error: \(failure.shell.rawValue): \(failure.message)")
            }
            if !outcome.succeeded { throw ExitCode.failure }
        }
    }
}

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Link ed and edith into a directory on PATH.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Install into this directory instead of the default.")
    var directory: String?

    func run() async throws {
        try await execute {
            let target = directory.map {
                URL(fileURLWithPath: $0.expandingTilde())
            }
            let outcome = TerminalToolingOperationExecution.install(into: target)
            let result = outcome.result
            if let message = result.message {
                throw CLIFailure(message)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "directory": .string(result.directory),
                        "linked": .strings(result.linked),
                        "skipped": .strings(result.skipped),
                        "onPath": .bool(outcome.onPath),
                        "message": .optional(result.message),
                    ]))
                return
            }
            CLIOut.out(
                result.linked.isEmpty
                    ? "already installed in \(result.directory)"
                    : "linked \(result.linked.joined(separator: ", ")) in \(result.directory)")
            if !outcome.onPath {
                CLIOut.note("note: \(result.directory) is not on PATH")
            }
        }
    }
}

struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Remove the ed and edith links.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        let result = TerminalToolingOperationExecution.remove().result
        if let message = result.message { throw CLIFailure(message) }
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

private func toolStatusJSON(_ status: CLIToolStatus) -> JSONValue {
    .object([
        "directory": .string(status.directory),
        "linked": .strings(status.linked),
        "missing": .strings(status.missing),
        "onPath": .bool(status.onPath),
        "bundled": .bool(status.bundled),
        "complete": .bool(status.isComplete),
    ])
}

private func completionStatusJSON(_ status: CompletionStatus) -> JSONValue {
    .object([
        "shell": .string(status.shell.rawValue),
        "state": .string(status.state.rawValue),
        "path": .string(status.path.path),
        "hint": .optional(status.hint),
    ])
}

private func completionInstallJSON(_ outcome: TerminalCompletionInstallOutcome) -> JSONValue {
    .object([
        "installed": .array(
            outcome.installed.map {
                .object([
                    "shell": .string($0.shell.rawValue),
                    "path": .string($0.path.path),
                    "hint": .optional($0.hint),
                ])
            }),
        "failures": .array(
            outcome.failures.map {
                .object([
                    "shell": .string($0.shell.rawValue),
                    "message": .string($0.message),
                ])
            }),
    ])
}

struct CompleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__complete", abstract: "Emit completion candidates.", shouldDisplay: false)

    @Option(help: "Zero based index of the word being completed.")
    var index: Int = 0

    @Argument(parsing: .captureForPassthrough)
    var words: [String] = []

    func run() async throws {
        let machines = MachineDirectoryCache.machines()
        let request = CompletionRequest(
            words: CompletionRequest.stripSeparator(words), index: index)
        let shelfItems: [String]
        if request.leading.first == "shelf" {
            let items = ShelfMutationExecution.snapshotIfUncontended()?.items ?? []
            shelfItems = items.indices.map { String($0 + 1) }
        } else {
            shelfItems = []
        }
        let musicTracks: [String]
        if request.leading.starts(with: ["music", "favorite"])
            || request.leading.starts(with: ["music", "favourite"])
            || request.leading.starts(with: ["music", "unfavorite"])
            || request.leading.starts(with: ["music", "unfavourite"])
            || request.leading.starts(with: ["music", "reveal"])
        {
            musicTracks =
                (try? LibraryBridge.requireFolder()) == nil
                ? [] : TrackMeta.scanMusicFolder().map(\.relativePath)
        } else {
            musicTracks = []
        }
        let calendarEvents: [String]
        if request.leading.starts(with: ["calendar", "join"])
            || request.leading.starts(with: ["calendar", "directions"]),
            let events = try? await CalendarBridge.events(timeout: 0.35)
        {
            calendarEvents = events.map(\.id)
        } else {
            calendarEvents = []
        }
        let quinjetSessionCommands = ["status", "focus", "close", "restart", "switch"]
        let quinjetSessions: [String]
        if request.leading.first == "quinjet",
            request.leading.dropFirst().first.map(quinjetSessionCommands.contains) == true,
            let result = try? await QuinjetSessionCLI.request(.sessions, timeout: 0.25)
        {
            quinjetSessions = result.sessions.map { String($0.index) }
        } else {
            quinjetSessions = []
        }
        let usageDocument =
            request.leading.first == "usage" ? (try? UsageDocument.load()) : nil
        let usageChatIDs =
            request.leading.starts(with: ["usage", "projects", "copy-chat"])
            ? UsageAnalysis.chatIDs(usageDocument?.daily ?? []) : []
        let usageProjects =
            request.leading.starts(with: ["usage", "projects", "show"])
                || request.leading.starts(with: ["usage", "projects", "open"])
                || request.leading.starts(with: ["usage", "projects", "copy-link"])
            ? UsageAnalysis.projectSelectors(usageDocument?.daily ?? []) : []
        let runningApps =
            request.leading.first == "apps"
            ? RunningAppOperationCenter().completionValues() : []
        let appLinks =
            request.leading.first == "app"
            ? AppInspectionCLI.center.links(
                contributors: AppInspectionCLI.contributors
            ).map(\.id)
            : []
        let result = CompletionEngine.plan(
            request, machines: MachineDirectory.names(from: machines),
            configKeys: ConfigCatalog.keys,
            extensionIDs: ExtensionRegistry.entries.map(\.id), shelfItems: shelfItems,
            musicTracks: musicTracks, calendarEvents: calendarEvents,
            toolIDs: ToolProvisioning.all.map(\.id),
            usageSources: usageDocument?.sources?.sorted() ?? [],
            runningApps: runningApps,
            appLinks: appLinks, usageChatIDs: usageChatIDs, usageProjects: usageProjects,
            quinjetSessions: quinjetSessions)
        if let name = result.remoteMachine,
            let machine = try? MachineDirectory.resolve(
                name, in: machines)
        {
            for candidate in await RemoteCompletion.candidates(
                machine: machine, request: result.remoteRequest ?? request)
            {
                CLIOut.out(candidate)
            }
            return
        }
        for line in result.lines { CLIOut.out(line) }
    }
}
