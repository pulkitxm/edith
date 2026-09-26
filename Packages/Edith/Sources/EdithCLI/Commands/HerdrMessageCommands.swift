import ArgumentParser
import EdithKit
import Foundation

enum HerdrMessageCLI {
    static let groups = ["working", "stopped"]

    static func message(_ raw: String) throws -> String {
        guard let text = HerdrAgentPrompt.normalized(raw) else {
            throw CLIFailure.usage("the message is empty", hint: "pass the text to send")
        }
        return text
    }

    static func recipients(
        group: String, session: String?, hosts: [HerdrHostSnapshot]
    ) -> [HerdrAgent] {
        hosts.flatMap(\.agents).filter { agent in
            guard !agent.isTerminal else { return false }
            if let session, agent.session != session { return false }
            return group == "working"
                ? agent.status == .working : agent.status == .idle || agent.status == .done
        }
    }

    static func resultJSON(_ agent: HerdrAgent, _ outcome: HerdrPromptOutcome) -> JSONValue {
        .object([
            "id": .string(agent.id),
            "machineName": .string(agent.machineName),
            "pane": .string(agent.pane),
            "session": .string(agent.session),
            "title": .string(agent.title),
            "result": .string(outcome.code),
            "detail": .string(outcome.summary),
        ])
    }

    static func resultsJSON(_ results: [(HerdrAgent, HerdrPromptOutcome)]) -> JSONValue {
        .object([
            "executed": .bool(true),
            "failures": .strings(
                results.filter { !$0.1.delivered }.map { "\($0.0.pane): \($0.1.summary)" }),
            "results": .array(results.map(resultJSON)),
            "submitted": .int(results.filter { $0.1.delivered }.count),
        ])
    }

    static func hookJSON(_ hook: HerdrAgentHook) -> JSONValue {
        .object([
            "id": .string(hook.id.uuidString),
            "agent": .string(hook.agentID),
            "machine": .string(hook.machineID),
            "session": .string(hook.session),
            "pane": .string(hook.pane),
            "title": .string(hook.title),
            "message": .string(hook.message),
            "state": .string(hook.phase.rawValue),
            "detail": .optional(hook.detail),
        ])
    }

    static func agentFailure(_ error: Error) -> Error {
        guard let error = error as? AgentError else { return error }
        if error.kind == .refused { return CLIFailure.usage(error.message) }
        return CLIFailure.unavailable("background agent", hint: error.message)
    }
}

struct HerdrSendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Type a message into one agent, or into every working or stopped agent.")

    @Argument(help: "A pane id such as w3:p1N, or working, or stopped.")
    var target: String

    @Argument(help: "The message to type into the agent.")
    var message: String

    @Option(help: "Only this machine, or local for this Mac.")
    var machine: String?

    @Option(help: "Herdr session name when more than one pane matches.")
    var session: String?

    @Flag(
        name: .customLong("when-finished"),
        help: "Send it the next time the agent finishes a turn instead of now.")
    var whenFinished = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let text = try HerdrMessageCLI.message(message)
            let group = target.lowercased()
            if HerdrMessageCLI.groups.contains(group) {
                guard !whenFinished else {
                    throw CLIFailure.usage(
                        "--when-finished needs one pane", hint: "pass a pane id instead")
                }
                try await broadcast(text, group: group)
                return
            }
            let hosts = try await HerdrCLI.collect(machine)
            let agent = try HerdrCLI.matching(pane: target, session: session, hosts: hosts)
            guard !agent.isTerminal else {
                throw CLIFailure.usage(
                    "\(target) is a terminal, not an agent", hint: "pick an agent pane")
            }
            if whenFinished {
                try await arm(text, for: agent)
            } else {
                try await send(text, to: agent)
            }
        }
    }

    private func broadcast(_ text: String, group: String) async throws {
        let hosts = try await HerdrCLI.collect(machine)
        let agents = HerdrMessageCLI.recipients(group: group, session: session, hosts: hosts)
        let outcomes = await HerdrAgentPrompt.broadcast(text, to: agents)
        let results = agents.map { ($0, outcomes[$0.id] ?? .failed("no reply")) }
        guard !json else {
            CLIOut.json(HerdrMessageCLI.resultsJSON(results))
            return
        }
        guard !agents.isEmpty else {
            CLIOut.note("no \(group) agents")
            return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["MACHINE", "PANE", "TITLE", "RESULT"],
                rows: results.map { [$0.0.machineName, $0.0.pane, $0.0.title, $0.1.summary] }))
    }

    private func send(_ text: String, to agent: HerdrAgent) async throws {
        let outcome = await HerdrAgentPrompt.send(text, to: agent)
        if json {
            CLIOut.json(HerdrMessageCLI.resultsJSON([(agent, outcome)]))
        } else if outcome.delivered {
            CLIOut.out("submitted to \(agent.title)")
        }
        guard outcome.delivered else { throw CLIFailure(outcome.summary) }
    }

    private func arm(_ text: String, for agent: HerdrAgent) async throws {
        let snapshot: HerdrHooksSnapshot
        do {
            snapshot = try await HerdrHookClient().arm(text, for: agent)
        } catch {
            throw HerdrMessageCLI.agentFailure(error)
        }
        guard let hook = snapshot.armed(for: agent.id) else {
            throw CLIFailure("the background agent did not keep the message")
        }
        guard !json else {
            CLIOut.json(HerdrMessageCLI.hookJSON(hook))
            return
        }
        CLIOut.out("\(agent.title) gets it when it finishes (\(hook.id.uuidString))")
    }
}

struct HerdrHooksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hooks",
        abstract: "Messages waiting for an agent to finish, and how the last ones went.",
        subcommands: [HerdrHooksListCommand.self, HerdrHooksRemoveCommand.self],
        defaultSubcommand: HerdrHooksListCommand.self)
}

struct HerdrHooksListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List waiting and recent finished-agent messages.",
        aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let snapshot: HerdrHooksSnapshot
            do {
                snapshot = try await HerdrHookClient().list()
            } catch {
                throw HerdrMessageCLI.agentFailure(error)
            }
            guard !json else {
                CLIOut.json(
                    .object(["hooks": .array(snapshot.hooks.map(HerdrMessageCLI.hookJSON))]))
                return
            }
            guard !snapshot.hooks.isEmpty else {
                CLIOut.note("no messages are waiting")
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["ID", "PANE", "TITLE", "STATE", "MESSAGE"],
                    rows: snapshot.hooks.map {
                        [
                            String($0.id.uuidString.prefix(8)), $0.pane, $0.title,
                            $0.detail.map { "\($0)" } ?? $0.phase.rawValue, $0.message,
                        ]
                    }))
        }
    }
}

struct HerdrHooksRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Cancel a waiting message or forget a finished one.",
        aliases: ["remove"])

    @Argument(help: "The hook id from `ed herdr hooks`, or a unique prefix of it.")
    var id: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let client = HerdrHookClient()
            do {
                let hooks = try await client.list().hooks
                let prefix = id.uppercased()
                let matches = hooks.filter { $0.id.uuidString.hasPrefix(prefix) }
                guard matches.count == 1, let hook = matches.first else {
                    throw CLIFailure.notFound(
                        matches.isEmpty ? "no hook \(id)" : "\(id) matches more than one hook",
                        hint: "run `ed herdr hooks` for the ids")
                }
                _ = try await client.remove(hook.id)
                guard !json else {
                    CLIOut.json(.object(["removed": .string(hook.id.uuidString)]))
                    return
                }
                CLIOut.out("removed \(hook.id.uuidString)")
            } catch let failure as CLIFailure {
                throw failure
            } catch {
                throw HerdrMessageCLI.agentFailure(error)
            }
        }
    }
}
