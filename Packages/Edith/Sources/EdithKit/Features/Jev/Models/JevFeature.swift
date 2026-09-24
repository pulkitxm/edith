import Foundation

public struct JevFeature: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }

    public static let catalog: [JevFeature] = [
        JevFeature(
            id: "mcp.find", title: "Tool finder for agents",
            detail:
                "ed mcp lists edith_find, which ranks Edith's tools for a plain-language request."),
        JevFeature(
            id: "cli.ask", title: "Raw requests",
            detail: "ed jev ask sends a state and typed questions for scripts and agents."),
    ]
}
