import ArgumentParser

struct DatabaseMCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve read-only database inspection over MCP stdio.")

    func run() async throws {
        try await execute {
            try await DatabaseCLIEnvironment.runMCPServer()
        }
    }
}
