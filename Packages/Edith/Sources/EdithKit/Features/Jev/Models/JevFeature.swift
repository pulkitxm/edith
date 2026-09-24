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
            id: DocsAsk.purpose, title: "Docs Ask",
            detail:
                "The Docs page and ed docs ask pick the command that handles a plain-language request."
        ),
        JevFeature(
            id: "cli.ask", title: "Raw requests",
            detail: "ed jev ask sends a state and typed questions for scripts and agents."),
        JevFeature(
            id: "agents.attention", title: "Agent attention",
            detail:
                "Reads a coding agent's screen when it changes state and decides whether it needs you."
        ),
        JevFeature(
            id: "agents.review", title: "Review readiness",
            detail: "Decides whether a finished agent's changes are ready for you to review."),
        JevFeature(
            id: "usage.limit-alerts", title: "Limit alerts that matter",
            detail:
                "On-pace, outlook and headroom limit alerts go out only when Jev judges them worth the interruption. Capped, almost capped, back and login alerts always go out."
        ),
        JevFeature(
            id: "presenter.detect", title: "Presenter detection",
            detail:
                "When no built-in rule matches, asks whether the on-screen windows show a shared screen. Opt in under Presenter."
        ),
    ]
}
