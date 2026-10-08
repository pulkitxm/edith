import ArgumentParser
import EdithKit
import Foundation

struct AgentActivityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activity", abstract: "Inspect live provider sessions and approval requests.",
        discussion: """
            Read Claude Code, Codex, and OpenCode activity delivered by configured hooks.
            status reads the live session snapshot. hook changes the activity feed and returns only a provider hook response.

            ed agent activity status --json
            """,
        subcommands: [AgentActivityStatusCommand.self, AgentActivityHookCommand.self],
        defaultSubcommand: AgentActivityStatusCommand.self)
}

struct AgentActivityStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show observed coding sessions and pending approvals.",
        discussion: """
            Read the live provider activity snapshot from the background agent.
            Reads session state and pending permission requests. Does not change provider configuration or decide requests.

            ed agent activity status --json
            """)
    @Flag(name: .long, help: "Emit the activity snapshot as JSON.") var json = false

    func run() async throws {
        try await execute {
            let snapshot = try await AgentClient.shared.snapshotAsync(
                AgentActivitySnapshot.self, topic: .agentActivity)
            if json {
                CLIOut.out(String(decoding: try AgentPayload.encode(snapshot), as: UTF8.self))
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

struct AgentActivityHookCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Forward a provider event and return its permission response.",
        discussion: """
            Accept one provider event as JSON on standard input and emit one hook response.
            Changes the activity feed. Permission requests wait for an explicit choice in Edith only when that provider's approval integration is enabled.

            ed agent activity hook --provider claude --integration-id edith-surfaces
            """, shouldDisplay: false)
    @Option(name: .long, help: "Provider event format: claude, codex, or opencode.") var provider:
        String
    @Option(name: .long, help: "Integration ownership identifier.") var integrationID: String

    func run() async throws {
        var choice: AgentApprovalChoice?
        let selected = AgentActivityProvider(rawValue: provider)
        if let selected, integrationID == "edith-surfaces" {
            do {
                var input = Data()
                while let chunk = try FileHandle.standardInput.read(upToCount: 16_384),
                    !chunk.isEmpty
                {
                    input.append(chunk)
                    if input.count > AgentActivityParser.maximumInputBytes { break }
                }
                if let event = try AgentActivityParser.parse(
                    input, provider: selected,
                    pane: ProcessInfo.processInfo.environment["TMUX_PANE"])
                {
                    choice = await AgentActivityHookRunner().run(event)
                }
            } catch {}
        }
        let output =
            (try? AgentActivityHookOutput.data(provider: selected ?? .claude, choice: choice))
            ?? Data("{}".utf8)
        try? FileHandle.standardOutput.write(contentsOf: output + Data("\n".utf8))
    }
}
