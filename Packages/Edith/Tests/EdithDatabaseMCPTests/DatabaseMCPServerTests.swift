import EdithDatabase
import MCP
import Testing

@testable import EdithDatabaseMCP

@Suite struct DatabaseMCPServerTests {
    @Test func servesCatalogAndBrokerBackedCallsOverMCPTransport() async throws {
        let sender = DatabaseMCPScriptedSender([
            .success(
                .connectionList(
                    .success(
                        DatabaseConnectionListResult(connections: []),
                        metadata: DatabaseMCPFixtures.completeMetadata)))
        ])
        let server = await DatabaseMCPServer(sender: sender).makeServer()
        let client = Client(name: "database-mcp-tests", version: "1.0.0")
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)
        let (tools, cursor) = try await client.listTools()
        let (content, isError) = try await client.callTool(
            name: "database_connections",
            arguments: ["action": "list"])
        await client.disconnect()
        await server.stop()

        #expect(cursor == nil)
        #expect(
            tools.map(\.name)
                == [
                    "database_connections", "database_capabilities", "database_browse",
                    "database_query",
                ])
        #expect(isError == false)
        guard case let .text(text, _, _)? = content.first else {
            Issue.record("Expected JSON text content.")
            return
        }
        #expect(text.contains("\"connections\":[]"))
        #expect(await sender.recordedRequests().count == 1)
    }
}
