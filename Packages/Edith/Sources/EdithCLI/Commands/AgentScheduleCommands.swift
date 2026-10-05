import ArgumentParser
import EdithKit
import Foundation

struct AgentScheduleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule", abstract: "Run commands on a schedule in the background agent.",
        discussion: """
            Add, list, remove, pause, or trigger commands that the daemon runs on an interval or a cron schedule.
            Reads the agent's schedule table. add, rm, enable, disable, and run change what the daemon runs. ls does not change anything.

            ed agent schedule ls
            ed agent schedule add backup --every 6h -- /usr/bin/true
            """,
        subcommands: [
            AgentScheduleListCommand.self, AgentScheduleAddCommand.self,
            AgentScheduleRemoveCommand.self, AgentScheduleEnableCommand.self,
            AgentScheduleDisableCommand.self, AgentScheduleRunCommand.self,
        ], defaultSubcommand: AgentScheduleListCommand.self)
}

enum AgentScheduleOutput {
    static func emit(_ snapshot: ScheduledTaskSnapshot, json: Bool) throws {
        if json {
            CLIOut.out(String(decoding: try AgentPayload.encode(snapshot), as: UTF8.self))
        } else {
            CLIOut.out(
                "\(snapshot.definition.name): \(snapshot.enabled ? "enabled" : "disabled"), \(snapshot.definition.schedule.text)"
            )
        }
    }

    static func date(_ value: Date?) -> String {
        value.map { $0.ISO8601Format() } ?? "-"
    }
}

struct AgentScheduleListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List scheduled commands with their next and last run.",
        discussion: """
            List every schedule with its state, next run, and last run.
            Reads the agent's schedule table. Does not change schedules.

            ed agent schedule ls
            ed agent schedule ls --json
            """)
    @Flag(name: .long, help: "Emit the schedules as JSON.") var json = false

    func run() async throws {
        try await execute {
            let schedules = try await AgentScheduleClient().list()
            if json {
                CLIOut.out(String(decoding: try AgentPayload.encode(schedules), as: UTF8.self))
            } else {
                CLIOut.out(
                    TextTable.render(
                        headers: ["NAME", "SCHEDULE", "STATE", "NEXT", "LAST", "COMMAND"],
                        rows: schedules.map {
                            [
                                $0.definition.name, $0.definition.schedule.text,
                                $0.enabled ? "enabled" : "disabled",
                                AgentScheduleOutput.date($0.nextRunAt),
                                [AgentScheduleOutput.date($0.lastRunAt), $0.lastState?.rawValue]
                                    .compactMap { $0 }.joined(separator: " "),
                                $0.definition.commandLine,
                            ]
                        }))
            }
        }
    }
}

struct AgentScheduleAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Schedule a command to run in the background agent.",
        discussion: """
            Run an absolute executable on an interval or a five-field cron schedule.
            Reads the command after --. Changes the agent by saving a schedule it keeps across restarts. A run missed while the agent was down is skipped. A run is skipped while the previous one is still going. Intervals run from 1 minute to 7 days.

            ed agent schedule add sync --every 15m -- /usr/bin/true
            ed agent schedule add nightly --cron "30 2 * * *" --timeout 3600 -- /usr/bin/true
            """)
    @Argument(help: "Schedule name: lowercase letters, digits, dots, dashes, underscores.")
    var name: String
    @Option(name: .long, help: "Run every interval, like 90s, 15m, 6h, or 1d.") var every: String?
    @Option(name: .long, help: "Run on a five-field cron expression, in quotes.") var cron: String?
    @Option(name: .long, help: "Absolute working directory. Defaults to the current directory.")
    var cwd: String?
    @Option(name: .long, help: "Maximum running time per run in seconds, up to 7200.")
    var timeout: Double = 300
    @Flag(name: .long, help: "Emit the schedule as JSON.") var json = false
    @Argument(parsing: .postTerminator, help: "Absolute executable and arguments, after --.")
    var command: [String]

    mutating func validate() throws {
        guard !command.isEmpty else {
            throw ValidationError("Provide an absolute executable path after --.")
        }
        guard (every == nil) != (cron == nil) else {
            throw ValidationError("Give exactly one of --every or --cron.")
        }
    }

    func run() async throws {
        try await execute {
            let definition = try ScheduledTaskDefinition(
                name: name, schedule: AgentSchedule.parse(every: every, cron: cron),
                executablePath: command[0], arguments: Array(command.dropFirst()),
                workingDirectory: cwd ?? FileManager.default.currentDirectoryPath,
                timeout: timeout)
            try AgentScheduleOutput.emit(
                try await AgentScheduleClient().add(definition), json: json)
        }
    }
}

struct AgentScheduleRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Remove a scheduled command.",
        discussion: """
            Remove one schedule by name.
            Reads the schedule name. Changes the agent by deleting that schedule. A run already going keeps going.

            ed agent schedule rm sync
            ed agent schedule rm sync --json
            """)
    @Argument(help: "Schedule name from ed agent schedule ls.") var name: String
    @Flag(name: .long, help: "Emit the result as JSON.") var json = false

    func run() async throws {
        try await execute {
            try await AgentScheduleClient().remove(name)
            if json {
                CLIOut.out(
                    String(
                        decoding: try AgentPayload.encode(RemovedSchedule(name: name)),
                        as: UTF8.self))
            } else {
                CLIOut.out("removed \(name)")
            }
        }
    }
}

private struct RemovedSchedule: Codable {
    let name: String
    var removed = true
}

struct AgentScheduleEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable", abstract: "Resume a paused scheduled command.",
        discussion: """
            Resume one paused schedule.
            Reads the schedule name. Changes the agent by scheduling the next run from now.

            ed agent schedule enable sync
            """)
    @Argument(help: "Schedule name from ed agent schedule ls.") var name: String
    @Flag(name: .long, help: "Emit the schedule as JSON.") var json = false

    func run() async throws {
        try await execute {
            try AgentScheduleOutput.emit(
                try await AgentScheduleClient().setEnabled(name, true), json: json)
        }
    }
}

struct AgentScheduleDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable", abstract: "Pause a scheduled command.",
        discussion: """
            Pause one schedule without deleting it.
            Reads the schedule name. Changes the agent so no new run starts. A run already going keeps going.

            ed agent schedule disable sync
            """)
    @Argument(help: "Schedule name from ed agent schedule ls.") var name: String
    @Flag(name: .long, help: "Emit the schedule as JSON.") var json = false

    func run() async throws {
        try await execute {
            try AgentScheduleOutput.emit(
                try await AgentScheduleClient().setEnabled(name, false), json: json)
        }
    }
}

struct AgentScheduleRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Run a scheduled command now.",
        discussion: """
            Queue one schedule's command immediately and print the task id.
            Reads the schedule name. Changes the task queue by submitting the run. The next scheduled run does not move. Follow the run with ed agent tasks inspect.

            ed agent schedule run sync
            """)
    @Argument(help: "Schedule name from ed agent schedule ls.") var name: String
    @Flag(name: .long, help: "Emit the task as JSON.") var json = false

    func run() async throws {
        try await execute {
            let snapshot = try await AgentScheduleClient().runNow(name)
            if json {
                CLIOut.out(String(decoding: try AgentPayload.encode(snapshot), as: UTF8.self))
            } else {
                CLIOut.out(snapshot.id.uuidString)
            }
        }
    }
}
