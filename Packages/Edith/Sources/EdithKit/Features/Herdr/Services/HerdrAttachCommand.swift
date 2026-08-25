import Foundation

public enum HerdrAttachCommand {
    public static func line(for agent: HerdrAgent) -> String {
        if agent.isTerminal { return HerdrMachineTerminal.line(for: agent) }
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
}
