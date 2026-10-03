import ArgumentParser
import EdithKit
import Foundation

struct UsageStatusLineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "statusline",
        abstract: "Connect Claude Code's status line so Edith reads Claude limits.",
        discussion: """
            Claude Code passes its 5-hour and 7-day rate limits to the command in the
            statusLine setting of its settings.json. Edith reads Claude limits from that
            feed, so Claude limits update while you use Claude Code.

            Changes the state the subcommand names.

            ed usage statusline install
            ed usage statusline remove
            """,
        subcommands: [
            UsageStatusLineStatusCommand.self, UsageStatusLineInstallCommand.self,
            UsageStatusLineRemoveCommand.self, UsageStatusLineRecordCommand.self,
        ],
        defaultSubcommand: UsageStatusLineStatusCommand.self)
}

struct UsageStatusLineStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether Claude Code's status line feeds Edith.",
        discussion: """
            Shows whether the statusLine setting in Claude Code's settings.json runs
            Edith's recorder, which earlier command it wraps, and when Claude Code last
            passed its windows to Edith.

            Reads the settings and the limits history. Does not change them.

            ed usage statusline status
            ed usage statusline status --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Claude Code settings file to read.")
    var settings: String?

    func run() async throws {
        try await execute {
            let url = settings.map { URL(fileURLWithPath: $0) } ?? ClaudeStatusLine.settingsURL()
            let command = ClaudeStatusLine.installedCommand(settings: url)
            let wraps = command.flatMap(ClaudeStatusLine.wrappedCommand)
            let recordedAt = LimitsHistory.latest(provider: .claude)?.date
            guard !json else {
                CLIOut.json(
                    .object([
                        "installed": .bool(command != nil),
                        "settings": .string(url.path),
                        "wraps": .optional(wraps),
                        "recordedAt": .date(recordedAt),
                    ]))
                return
            }
            guard command != nil else {
                CLIOut.out(
                    "Not installed (\(url.path)). Run `ed usage statusline install` to connect it.")
                return
            }
            CLIOut.out("Installed (\(url.path))")
            if let wraps { CLIOut.out("Runs your previous command next: \(wraps)") }
            CLIOut.out(
                "Last recorded: "
                    + (recordedAt.map { JSONSerializer.iso.string(from: $0) } ?? "nothing yet"))
        }
    }
}

struct UsageStatusLineInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install Edith as Claude Code's status line command.",
        discussion: """
            Sets statusLine in Claude Code's settings.json, in CLAUDE_CONFIG_DIR when it
            is set, so Claude Code runs `ed usage statusline record`. A status line
            command you already had keeps running and keeps its output. Claude Code picks
            the change up on its next status line refresh.

            Writes Claude Code's settings.json.

            ed usage statusline install
            ed usage statusline install --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Claude Code settings file to change.")
    var settings: String?

    func run() async throws {
        try await execute {
            let url = settings.map { URL(fileURLWithPath: $0) } ?? ClaudeStatusLine.settingsURL()
            guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path
            else {
                throw CLIFailure.unavailable("could not locate the ed executable")
            }
            let change = try ClaudeStatusLine.install(executable: executable, settings: url)
            guard !json else {
                CLIOut.json(
                    .object(["settings": .string(url.path), "change": .string(change.rawValue)]))
                return
            }
            switch change {
            case .wrapped:
                CLIOut.out(
                    "Claude Code now runs Edith's status line, then your previous one (\(url.path))"
                )
            case .unchanged:
                CLIOut.out("Edith's status line is already installed (\(url.path))")
            default:
                CLIOut.out("Claude Code now runs Edith's status line (\(url.path))")
            }
        }
    }
}

struct UsageStatusLineRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove Edith from Claude Code's status line.",
        discussion: """
            Removes the statusLine setting that `ed usage statusline install` added, or
            puts back the status line command it wrapped. Edith stops receiving Claude
            limits until you install it again.

            Writes Claude Code's settings.json.

            ed usage statusline remove
            ed usage statusline remove --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Claude Code settings file to change.")
    var settings: String?

    func run() async throws {
        try await execute {
            let url = settings.map { URL(fileURLWithPath: $0) } ?? ClaudeStatusLine.settingsURL()
            let change = try ClaudeStatusLine.remove(settings: url)
            guard !json else {
                CLIOut.json(
                    .object(["settings": .string(url.path), "change": .string(change.rawValue)]))
                return
            }
            switch change {
            case .restored:
                CLIOut.out("Restored your previous status line command (\(url.path))")
            case .absent:
                CLIOut.out("Edith's status line is not installed (\(url.path))")
            default:
                CLIOut.out("Removed Edith's status line (\(url.path))")
            }
        }
    }
}

struct UsageStatusLineRecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Save the windows Claude Code passes to its status line.",
        discussion: """
            Claude Code runs this command once `ed usage statusline install` has set it up.
            It reads the status line JSON on standard input, saves the 5-hour and 7-day
            windows to the limits history and prints a short line such as
            `5h 42% · 7d 18%`. With --then it runs that command with the same input and
            prints its output instead.

            Writes the limits history.

            ed usage statusline record < status.json
            ed usage statusline record --input status.json --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Read the status line JSON from this file instead of stdin.")
    var input: String?

    @Option(name: .long, help: "Status line command to run next with the same input.")
    var then: String?

    func run() async throws {
        try await execute {
            if json, then != nil {
                throw CLIFailure.usage("--then cannot be combined with --json")
            }
            let data: Data
            if let input {
                do {
                    data = try Data(contentsOf: URL(fileURLWithPath: input))
                } catch {
                    throw CLIFailure.notFound("no status line input at \(input)")
                }
            } else {
                data = FileHandle.standardInput.readDataToEndOfFile()
            }
            let limits = ClaudeStatusLine.record(data)
            if json {
                CLIOut.json(
                    .object([
                        "recorded": .bool(limits != nil),
                        "line": .string(limits.map(ClaudeStatusLine.line) ?? ""),
                        "session": LimitsReport.window(limits?.session),
                        "week": LimitsReport.window(limits?.week),
                    ]))
                return
            }
            if let then {
                FileHandle.standardOutput.write(Self.output(of: then, input: data))
                return
            }
            if let limits { CLIOut.out(ClaudeStatusLine.line(for: limits)) }
        }
    }

    static func output(of command: String, input: Data) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        guard (try? process.run()) != nil else { return Data() }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return output
    }
}
