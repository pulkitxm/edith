import ArgumentParser
import EdithKit
import Foundation

enum AgentCLI {
    static func snapshot() throws -> AgentRuntimeSnapshot {
        do {
            return try AgentClient.shared.runtimeSnapshot()
        } catch let error as AgentError {
            throw CLIFailure.unavailable(
                "background agent", hint: error.message)
        }
    }

    static func jobs() throws -> [AgentJobSnapshot] {
        do {
            return try AgentClient.shared.jobSnapshots()
        } catch let error as AgentError {
            throw CLIFailure.unavailable("background agent", hint: error.message)
        }
    }

    static func statusJSON(_ snapshot: AgentRuntimeSnapshot) -> JSONValue {
        .object([
            "state": .string(AgentRegistrationState.current.rawValue),
            "build": .string(snapshot.build),
            "pid": .int(Int(snapshot.processIdentifier)),
            "uptimeSeconds": .int(Int(snapshot.uptime)),
            "residentBytes": .int(Int(snapshot.residentBytes)),
            "cpuPercent": .double(snapshot.cpuPercent),
            "subscribers": .int(snapshot.subscriberCount),
            "store": .string(snapshot.storePath),
            "schemaVersion": .int(snapshot.schemaVersion),
            "protocolVersion": .int(AgentService.protocolVersion),
        ])
    }

    static func jobJSON(_ snapshot: AgentJobSnapshot) -> JSONValue {
        .object([
            "id": .string(snapshot.descriptor.id),
            "title": .string(snapshot.descriptor.title),
            "trigger": .string(snapshot.descriptor.trigger.rawValue),
            "topic": .optional(snapshot.descriptor.topic?.rawValue),
            "ambientSeconds": snapshot.descriptor.cadence.ambient.map { .int(Int($0)) } ?? .null,
            "liveSeconds": snapshot.descriptor.cadence.live.map { .int(Int($0)) } ?? .null,
            "power": .string(snapshot.descriptor.power.rawValue),
            "phase": .string(snapshot.phase.rawValue),
            "subscribers": .int(snapshot.subscribers),
            "runCount": .int(snapshot.runCount),
            "lastError": .optional(snapshot.lastError),
        ])
    }

    static func cadenceLabel(_ snapshot: AgentJobSnapshot) -> String {
        let ambient = snapshot.descriptor.cadence.ambient.map(duration) ?? "on demand"
        guard let live = snapshot.descriptor.cadence.live else { return ambient }
        return "\(ambient), live \(duration(live))"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

struct AgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Inspect and control the Edith background agent.",
        subcommands: [
            AgentStatusCommand.self, AgentJobsCommand.self, AgentRestartCommand.self,
            AgentLogsCommand.self,
        ],
        defaultSubcommand: AgentStatusCommand.self)
}

struct AgentStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show whether the background agent is running.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let snapshot = try AgentCLI.snapshot()
            guard !json else {
                CLIOut.json(AgentCLI.statusJSON(snapshot))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["FIELD", "VALUE"],
                    rows: [
                        ["state", AgentRegistrationState.current.title],
                        ["build", snapshot.build],
                        ["pid", String(snapshot.processIdentifier)],
                        ["uptime", AgentCLI.duration(snapshot.uptime)],
                        [
                            "memory",
                            ByteCountFormatter.string(
                                fromByteCount: Int64(snapshot.residentBytes), countStyle: .memory),
                        ],
                        ["cpu", String(format: "%.1f%%", snapshot.cpuPercent)],
                        ["subscribers", String(snapshot.subscriberCount)],
                        ["store", snapshot.storePath],
                        ["schema", String(snapshot.schemaVersion)],
                    ]))
        }
    }
}

struct AgentJobsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jobs", abstract: "List the jobs the background agent runs.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let jobs = try AgentCLI.jobs()
            guard !json else {
                CLIOut.json(.array(jobs.map(AgentCLI.jobJSON)))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["ID", "STATE", "TRIGGER", "CADENCE", "SUBS"],
                    rows: jobs.map { job in
                        [
                            job.descriptor.id, job.phase.title,
                            job.descriptor.trigger.title, AgentCLI.cadenceLabel(job),
                            String(job.subscribers),
                        ]
                    }))
        }
    }
}

struct AgentRestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart", abstract: "Ask launchd to restart the background agent.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            do {
                try AgentClient.shared.restart()
            } catch let error as AgentError {
                throw CLIFailure.unavailable("background agent", hint: error.message)
            }
            guard !json else {
                CLIOut.json(.object(["restarted": .bool(true)]))
                return
            }
            CLIOut.out("background agent restarting")
        }
    }
}

struct AgentLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs", abstract: "Print recent background agent log lines.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "How far back to read.")
    var last = "1h"

    func run() async throws {
        try await execute {
            let lines: [String]
            do {
                lines = try AgentClient.shared.logLines(last: last)
            } catch let error as AgentError {
                throw CLIFailure.unavailable("background agent", hint: error.message)
            }
            guard !json else {
                CLIOut.json(.array(lines.map { .string($0) }))
                return
            }
            for line in lines { CLIOut.out(line) }
        }
    }
}
