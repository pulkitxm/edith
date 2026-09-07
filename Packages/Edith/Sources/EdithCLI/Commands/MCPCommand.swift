import ArgumentParser

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve every Edith operation over MCP stdio.",
        discussion: """
            Each registered operation becomes one tool that runs its `ed` route and
            returns the JSON. Destructive routes preview until you pass confirm.
            """)

    func run() async throws {
        try await execute {
            try await OperationMCPServer().run()
        }
    }
}
