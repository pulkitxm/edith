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

    public static let findToolName = "edith_find"

    public static var findTool: Tool {
        Tool(
            name: findToolName, title: "Find an Edith tool",
            description:
                "Rank the Edith tools that serve a plain-language request, using TypeSafe Jev. "
                + "Returns tool names, summaries and probabilities.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "request": .object([
                        "type": "string", "description": "What you want Edith to do.",
                    ])
                ]),
                "required": .array(["request"]),
            ]))
    }

    public static func listedTools(jevConfigured: Bool) -> [Tool] {
        tools + (jevConfigured ? [findTool] : []) + DatabaseMCPToolCatalog.tools
    }

    static func findGroups() -> [JevRouteGroup] {
        Dictionary(grouping: OperationMCPCatalog.tools) { $0.route.first ?? $0.name }
            .map { area, tools in
                JevRouteGroup(
                    id: area, summary: CommandTree.root.child(area)?.summary ?? area,
                    members: tools.map { JevRouteCandidate(id: $0.name, summary: $0.summary) })
            }
            .sorted { $0.id < $1.id }
    }

    static func find(
        _ parameters: CallTool.Parameters, decider: JevDeciding? = AgentJevDecider.configured()
    ) async -> CallTool.Result {
        guard let decider else {
            return CallTool.Result(
                content: [
                    .text(
                        text: JevError.missingKey.localizedDescription, annotations: nil, _meta: nil
                    )
                ], isError: true)
        }
        guard let request = parameters.arguments?["request"]?.stringValue,
            !request.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return CallTool.Result(
                content: [.text(text: "Pass the request to route.", annotations: nil, _meta: nil)],
                isError: true)
        }
        do {
            let result = try await JevRouter(groups: findGroups()).route(
                request, using: decider, purpose: "mcp.find")
            let summaries = Dictionary(
                OperationMCPCatalog.tools.map { ($0.name, $0.summary) },
                uniquingKeysWith: { first, _ in first })
            let rows = result.picks.map { pick in
                JSONValue.object([
                    "tool": .string(pick.id), "summary": .string(summaries[pick.id] ?? ""),
                    "probability": .double(pick.probability),
                ])
            }
            return CallTool.Result(
                content: [
                    .text(
                        text: JSONSerializer.string(
                            .object(["tools": .array(rows), "latencyMs": .int(result.milliseconds)])
                        ),
                        annotations: nil, _meta: nil)
                ], isError: false)
        } catch {
            return CallTool.Result(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true)
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
            ListTools.Result(tools: Self.listedTools(jevConfigured: JevAvailability.isConfigured()))
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await Self.call(parameters)
        }
        return server
    }

    static func call(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        if parameters.name == findToolName { return await find(parameters) }
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
