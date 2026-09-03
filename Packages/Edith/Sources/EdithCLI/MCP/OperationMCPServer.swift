import EdithDatabaseMCP
import EdithKit
import Foundation
import MCP

public struct OperationMCPServer: Sendable {
    public init() {}

    public static func schema(for tool: OperationMCPTool) -> Value {
        var properties: [String: Value] = [
            "arguments": .object([
                "type": "array",
                "items": .object(["type": "string"]),
                "description":
                    "Positional arguments and flags, exactly as `\(tool.title)` accepts them.",
            ])
        ]
        if tool.isDestructive {
            properties["confirm"] = .object([
                "type": "boolean",
                "description":
                    "Leave false to preview. Pass true to apply, which adds --yes.",
            ])
        }
        return .object(["type": "object", "properties": .object(properties)])
    }

    public static func description(for tool: OperationMCPTool) -> String {
        guard tool.isDestructive else { return tool.summary }
        return tool.summary + " Previews by default; pass confirm to apply."
    }

    public static var tools: [Tool] {
        OperationMCPCatalog.tools.map { tool in
            Tool(
                name: tool.name, title: tool.title, description: description(for: tool),
                inputSchema: schema(for: tool))
        }
    }

    public func makeServer() async -> Server {
        let server = Server(
            name: "edith",
            version: edithCLIVersion,
            title: "Edith",
            instructions:
                "Every tool runs one `ed` route and returns its JSON. Destructive routes preview "
                + "until you pass confirm.",
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.tools + DatabaseMCPToolCatalog.tools)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await Self.call(parameters)
        }
        return server
    }

    static func call(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        guard let tool = OperationMCPCatalog.tool(named: parameters.name) else {
            return await DatabaseMCPToolHandler().callTool(parameters)
        }
        let arguments = (parameters.arguments?["arguments"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
        let confirm = parameters.arguments?["confirm"]?.boolValue ?? false
        let invocation = await OperationMCPRunner.run(
            tool, arguments: arguments, confirm: confirm)
        return CallTool.Result(
            content: [.text(invocation.output)], isError: invocation.failed)
    }

    public func run() async throws {
        let server = await makeServer()
        let stdio = StdioTransport()
        let transport = DatabaseMCPSerialTransport(base: stdio, logger: stdio.logger)
        try await withTaskCancellationHandler {
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } onCancel: {
            Task { await server.stop() }
        }
        await server.stop()
    }
}
