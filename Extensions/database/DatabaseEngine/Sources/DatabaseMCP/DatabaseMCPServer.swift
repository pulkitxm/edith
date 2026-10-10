import DatabaseCore
import MCP

public struct DatabaseMCPServer: Sendable {
    private let handler: DatabaseMCPToolHandler

    public init(
        sender: any DatabaseBrokerCommandSending,
        makeOperationID: @escaping @Sendable () -> DatabaseOperationID = {
            DatabaseOperationID()
        }
    ) {
        handler = DatabaseMCPToolHandler(
            sender: sender,
            makeOperationID: makeOperationID)
    }

    public func makeServer() async -> Server {
        let server = Server(
            name: "edith-database",
            version: "1.0.0",
            title: "Edith Database",
            instructions: "Use bounded database tools with explicit saved connection identifiers.",
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: DatabaseMCPToolCatalog.tools)
        }
        let handler = handler
        await server.withMethodHandler(CallTool.self) { parameters in
            await handler.callTool(parameters)
        }
        return server
    }

    public func run(transport base: any Transport) async throws {
        let server = await makeServer()
        let transport = DatabaseMCPSerialTransport(base: base, logger: await base.logger)
        do {
            try await withTaskCancellationHandler {
                try await server.start(transport: transport)
                await server.waitUntilCompleted()
            } onCancel: {
                Task {
                    await handler.shutdownAndWait()
                    await server.stop()
                }
            }
        } catch {
            await handler.shutdownAndWait()
            await server.stop()
            throw error
        }
        await handler.shutdownAndWait()
        await server.stop()
        try Task.checkCancellation()
    }
}
