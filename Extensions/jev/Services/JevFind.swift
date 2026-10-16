import Foundation

struct JevFindTool: Codable, Sendable, Equatable {
    let tool: String
    let summary: String
    let area: String
}

struct JevFindArguments: Codable, Sendable {
    let request: String?
    let tools: [JevFindTool]?
}

enum JevFind {
    static func groups(_ tools: [JevFindTool]) -> [JevRouteGroup] {
        Dictionary(grouping: tools, by: \.area)
            .map { area, members in
                JevRouteGroup(
                    id: area, summary: area,
                    members: members.map { JevRouteCandidate(id: $0.tool, summary: $0.summary) })
            }
            .sorted { $0.id < $1.id }
    }

    static func run(_ payload: Data, using decider: JevDeciding) async throws -> Data {
        let arguments = try JSONDecoder().decode(JevFindArguments.self, from: payload)
        guard let request = arguments.request,
            !request.trimmingCharacters(in: .whitespaces).isEmpty
        else { return try result("Pass the request to route.", isError: true) }
        let tools = arguments.tools ?? []
        do {
            let routed = try await JevRouter(groups: groups(tools)).route(
                request, using: decider, purpose: "mcp.find")
            let summaries = Dictionary(
                tools.map { ($0.tool, $0.summary) }, uniquingKeysWith: { first, _ in first })
            let rows: [[String: Any]] = routed.picks.map {
                ["tool": $0.id, "summary": summaries[$0.id] ?? "", "probability": $0.probability]
            }
            let body = try JSONSerialization.data(
                withJSONObject: ["tools": rows, "latencyMs": routed.milliseconds],
                options: [.sortedKeys, .withoutEscapingSlashes])
            return try result(String(decoding: body, as: UTF8.self), isError: false)
        } catch let error as JevError {
            return try result(error.localizedDescription, isError: true)
        }
    }

    private static func result(_ text: String, isError: Bool) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "content": [["type": "text", "text": text]], "isError": isError,
            ] as [String: Any])
    }
}
