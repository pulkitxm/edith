import ArgumentParser
import EdithKit
import Foundation

struct HerdrCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "herdr",
        abstract: "Live Herdr sessions on this Mac and your SSH machines.",
        discussion: """
            Edith asks `herdr` on this Mac and on every configured machine. Missing
            binaries are reported rather than treated as a failure, so a Mac without
            Herdr still lists the machines that have it.
            """,
        subcommands: [
            HerdrListCommand.self, HerdrAttachLineCommand.self, HerdrAttachCommandCLI.self,
            HerdrBridgeCommand.self,
        ],
        defaultSubcommand: HerdrListCommand.self)
}

enum HerdrCLI {
    static let localQueries: Set<String> = ["local", "this-mac", "thismac", "mac"]

    static func scope(_ query: String?) throws -> HerdrCollectScope {
        guard let query, !query.isEmpty else { return .all }
        if localQueries.contains(query.lowercased()) { return .local }
        return .machine(try MachineResolver.machine(query))
    }

    static func collect(_ query: String?) async throws -> [HerdrHostSnapshot] {
        await HerdrSessionOperationExecution.list(try scope(query))
    }

    static func json(_ hosts: [HerdrHostSnapshot]) -> JSONValue {
        let agents = hosts.flatMap(\.agents)
        return .object([
            "hosts": .array(hosts.map(hostJSON)),
            "agents": .array(agents.map(agentJSON)),
        ])
    }

    static func hostJSON(_ host: HerdrHostSnapshot) -> JSONValue {
        .object([
            "id": .string(host.id),
            "name": .string(host.name),
            "local": .bool(host.isLocal),
            "herdr": .bool(host.herdrPresent),
            "reachable": .bool(host.reachable),
            "error": .optional(host.error),
        ])
    }

    static func agentJSON(_ agent: HerdrAgent) -> JSONValue {
        .object([
            "id": .string(agent.id),
            "machine": .string(agent.machineID),
            "machineName": .string(agent.machineName),
            "local": .bool(agent.machineIsLocal),
            "session": .string(agent.session),
            "pane": .string(agent.pane),
            "kind": .string(agent.kind),
            "status": .string(agent.status.rawValue),
            "title": .string(agent.title),
            "workspace": .string(agent.workspace),
            "cwd": .string(agent.cwd),
            "command": .string(HerdrAttachCommand.line(for: agent)),
        ])
    }

    static func matching(
        pane: String, session: String?, hosts: [HerdrHostSnapshot]
    ) throws -> HerdrAgent {
        var agents = hosts.flatMap(\.agents).filter { agent in
            agent.pane == pane || agent.id == pane || agent.id.hasSuffix("|\(pane)")
        }
        if let session {
            agents = agents.filter { $0.session == session }
        }
        if agents.isEmpty {
            throw CLIFailure.notFound(
                "no herdr pane named \(pane)",
                hint: "run `ed herdr ls` and pass the pane id, or add --machine / --session")
        }
        if agents.count > 1 {
            let locations = agents.map { "\($0.machineName):\($0.session):\($0.pane)" }.joined(
                separator: ", ")
            throw CLIFailure.notFound(
                "\(pane) matches more than one pane",
                hint: "narrow with --machine or --session; matches: \(locations)")
        }
        return agents[0]
    }
}

struct HerdrListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List live Herdr sessions.", aliases: ["list"])

    @Option(help: "Only this machine, or local for this Mac.")
    var machine: String?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let hosts = try await HerdrCLI.collect(machine)
            let agents = hosts.flatMap(\.agents)
            guard !json else {
                CLIOut.json(HerdrCLI.json(hosts))
                return
            }
            let failures = hosts.filter {
                $0.error != nil && (!$0.reachable || $0.herdrPresent)
            }
            for host in failures {
                CLIOut.note("\(host.name): \(host.error ?? "inspection failed")")
            }
            if agents.isEmpty {
                let missing = hosts.filter { !$0.herdrPresent }.map(\.name)
                if failures.isEmpty, missing.count == hosts.count {
                    CLIOut.note(
                        "herdr is not installed on "
                            + missing.joined(separator: ", "))
                } else {
                    CLIOut.note("no herdr sessions")
                }
                return
            }
            let rows = agents.map { agent in
                [
                    agent.machineName, agent.kind, agent.status.rawValue, agent.pane,
                    agent.title,
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["MACHINE", "KIND", "STATUS", "PANE", "TITLE"], rows: rows))
        }
    }
}

struct HerdrAttachCommandCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach", abstract: "Attach this terminal to a live pane.")

    @Argument(help: "The pane id, for example w3:p1N.")
    var pane: String

    @Option(help: "Only this machine, or local for this Mac.")
    var machine: String?

    @Option(help: "Herdr session name when more than one pane matches.")
    var session: String?

    @Flag(name: .long, help: "Resolve the launch as JSON without attaching.")
    var json = false

    func run() async throws {
        try await execute {
            let hosts = try await HerdrCLI.collect(machine)
            let agent = try HerdrCLI.matching(pane: pane, session: session, hosts: hosts)
            let environment = ProcessInfo.processInfo.environment.keys.sorted().map {
                "\($0)=\(ProcessInfo.processInfo.environment[$0] ?? "")"
            }
            let request: TerminalLaunchRequest
            if agent.machineIsLocal {
                request = HerdrOperationExecution.localAttachRequest(
                    for: agent, environment: environment)
            } else {
                let runner = try await MachineResolver.runner(agent.machineID)
                let platform = await runner.ssh.remotePlatform ?? .linux
                request = HerdrOperationExecution.remoteAttachRequest(
                    for: agent, connection: runner.ssh, environment: environment,
                    platform: platform)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "arguments": .strings(request.arguments),
                        "attached": .bool(false),
                        "command": .string(HerdrAttachCommand.line(for: agent)),
                        "executable": .string(request.executable),
                        "local": .bool(agent.machineIsLocal),
                        "machine": .string(agent.machineName),
                        "pane": .string(agent.pane),
                        "session": .string(agent.session),
                    ]))
                return
            }
            let status = CLIEnvironment.launchTerminal(request)
            guard status == 0 else { throw ExitCode(status) }
        }
    }
}

struct HerdrAttachLineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "command",
        abstract: "Print the command that attaches to a pane.")

    @Argument(help: "The pane id, for example w3:p1N.")
    var pane: String

    @Option(help: "Only this machine, or local for this Mac.")
    var machine: String?

    @Option(help: "Herdr session name when more than one pane matches.")
    var session: String?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let hosts = try await HerdrCLI.collect(machine)
            let agent = try HerdrCLI.matching(pane: pane, session: session, hosts: hosts)
            let line = HerdrAttachCommand.line(for: agent)
            guard !json else {
                CLIOut.json(.object(["command": .string(line)]))
                return
            }
            CLIOut.out(line)
        }
    }
}
