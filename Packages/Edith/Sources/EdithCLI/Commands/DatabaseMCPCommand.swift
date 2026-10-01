import ArgumentParser

struct DatabaseMCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve read-only database inspection over MCP stdio.",
        discussion: """
            Runs the read-only Edith Database MCP server over standard input and output.

            Reads saved connections over MCP stdio. Does not change them.

            ed database mcp
            """, )

    func run() async throws {
        try await execute {
            try await DatabaseCLIEnvironment.runMCPServer()
        }
    }
}
