import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

enum HerdrAgentActivityCLIContext {
    @TaskLocal static var monitor: AgentActivityMonitor?
}

struct HerdrAgentCLICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent", abstract: "Inspect live provider activity.",
        subcommands: [HerdrAgentActivityCommand.self])
}

struct HerdrAgentActivityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activity", abstract: "Inspect live provider sessions and approval requests.",
        subcommands: [HerdrAgentActivityStatusCommand.self, HerdrAgentActivityHookCommand.self],
        defaultSubcommand: HerdrAgentActivityStatusCommand.self)
}

struct HerdrAgentActivityStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show observed coding sessions and pending approvals.")
    @Flag(name: .long, help: "Emit the activity snapshot as JSON.") var json = false

    func run() async throws {
        try await execute {
            guard let monitor = HerdrAgentActivityCLIContext.monitor else {
                throw CLIFailure.unavailable("The Herdr activity engine is unavailable.")
            }
            let data = try await monitor.execute("activity.status", payload: Data("{}".utf8))
            let snapshot = try AgentPayload.decode(AgentActivitySnapshot.self, from: data)
            if json {
                CLIOut.out(String(decoding: data, as: UTF8.self))
            } else {
                CLIOut.out(
                    TextTable.render(
                        headers: ["PROVIDER", "SESSION", "STATE", "TOOL"],
                        rows: snapshot.sessions.map {
                            [$0.provider.title, $0.sessionID, $0.phase.title, $0.tool ?? ""]
                        }))
                CLIOut.out("\(snapshot.approvals.count) pending approvals")
            }
        }
    }
}

struct HerdrAgentActivityHookCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Forward a provider event and return its permission response.",
        shouldDisplay: false)
    @Option(name: .long, help: "Provider event format.") var provider: String
    @Option(name: .long, help: "Integration ownership identifier.") var integrationID: String
    @Option(name: .long, help: "Originating terminal pane identifier.") var pane: String?

    func run() async throws {
        let selected = AgentActivityProvider(rawValue: provider)
        var output: Data?
        if let selected, integrationID == AgentActivityHookInstaller.integrationID,
            let monitor = HerdrAgentActivityCLIContext.monitor
        {
            do {
                var bytes = Data()
                if let input = ExtensionCLIContext.input {
                    while let event = try await input.read() {
                        if case .bytes(let chunk) = event { bytes.append(chunk) }
                        if bytes.count > AgentActivityParser.maximumInputBytes { break }
                    }
                } else {
                    bytes = ExtensionCLIContext.request?.standardInput ?? Data()
                }
                output = try await monitor.performHook(bytes, provider: selected, pane: pane)
            } catch {}
        }
        let fallback = try AgentActivityHookOutput.data(provider: selected ?? .claude, choice: nil)
        try CLIOut.raw((output ?? fallback) + Data("\n".utf8))
    }
}

@MainActor enum HerdrAgentCLIExecution {
    static func run(_ request: ExtensionCLIRequest, worker: HerdrWorker) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        let reply = try await HerdrAgentActivityCLIContext.$monitor.withValue(worker.activity) {
            try await ExtensionCLIExecution.run(HerdrAgentCLICommand.self, request: request)
        }
        try Task.checkCancellation()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return reply
    }

    static func invokeStream(
        _ operation: String, payload: Data, worker: HerdrWorker,
        streams: ExtensionCLIStreams
    ) throws -> Data {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return try HerdrAgentActivityCLIContext.$monitor.withValue(worker.activity) {
            try streams.invoke(
                HerdrAgentCLICommand.self, operation: operation,
                prefix: "herdr.agent.cli", payload: payload)
        }
    }

    static func catalog() throws -> [String: Any] {
        let bytes = Data(HerdrAgentCLICommand._dumpHelp().utf8)
        guard bytes.count <= 1_048_576,
            var parserHelp = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            parserHelp["serializationVersion"] as? Int == 0,
            var command = parserHelp["command"] as? [String: Any],
            command["commandName"] as? String == "agent",
            let children = command["subcommands"] as? [[String: Any]]
        else { throw ExtensionPeerError.invalidRequest }
        command["subcommands"] = children.filter { $0["commandName"] as? String == "activity" }
        parserHelp["command"] = command
        return [
            "version": 1, "owner": "herdr", "parserHelp": parserHelp,
            "routes": [
                [
                    "route": ["agent", "activity", "status"], "operation": "herdr.agent.cli",
                    "summary": HerdrAgentActivityStatusCommand.configuration.abstract,
                    "destructive": false, "timeout": 30, "readsInput": false, "jsonOutput": true,
                ],
                [
                    "route": ["agent", "activity", "hook"], "operation": "herdr.agent.cli",
                    "summary": HerdrAgentActivityHookCommand.configuration.abstract,
                    "destructive": true, "timeout": 120, "readsInput": true,
                    "streamOperation": "herdr.agent.cli", "streamDeadline": 120, "jsonOutput": true,
                ],
            ],
        ]
    }
}
