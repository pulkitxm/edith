import Foundation

public enum HerdrAttachCommand {
    public static func line(for agent: HerdrAgent) -> String {
        let attach = herdrLine(session: agent.session, pane: agent.pane)
        guard !agent.machineIsLocal, let target = agent.sshTarget, !target.isEmpty else {
            return attach
        }
        return "ssh -tt \(target) -- \(attach)"
    }

    public static func herdrLine(session: String, pane: String) -> String {
        "herdr --session \(session) agent attach \(pane)"
    }

    public static func remoteShellLine(session: String, pane: String) -> String {
        "export PATH=\"\(HerdrCollector.pathPrefix)\"; \(herdrLine(session: session, pane: pane))"
    }

    public static func arguments(session: String, pane: String) -> [String] {
        ["--session", session, "agent", "attach", pane]
    }

    public static func observerLine(session: String, pane: String, columns: Int, rows: Int)
        -> String
    {
        let history = ShellQuote.command(
            ["herdr"] + observerHistoryArguments(session: session, pane: pane))
        let observer = ShellQuote.command(
            ["herdr"]
                + observerArguments(
                    session: session, pane: pane, columns: columns, rows: rows))
        return
            "export PATH=\"\(HerdrCollector.pathPrefix)\"; \(history); printf '\\n'; exec \(observer)"
    }

    public static func observerHistoryArguments(session: String, pane: String) -> [String] {
        [
            "--session", session, "pane", "read", pane,
            "--source", "recent", "--lines", "500", "--format", "ansi",
        ]
    }

    public static func observerArguments(
        session: String, pane: String, columns: Int, rows: Int
    ) -> [String] {
        [
            "--session", session, "terminal", "session", "observe", pane,
            "--cols", String(columns), "--rows", String(rows),
        ]
    }
}
