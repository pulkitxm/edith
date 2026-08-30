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
        "herdr --session \(session) agent attach \(pane) --takeover"
    }

    public static func remoteShellLine(
        session: String, pane: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        remoteHerdrCommand(
            arguments: arguments(session: session, pane: pane), platform: platform)
    }

    public static func arguments(session: String, pane: String) -> [String] {
        ["--session", session, "agent", "attach", pane, "--takeover"]
    }
}

public enum HerdrTerminalControlCommand {
    public static func arguments(session: String, pane: String) -> [String] {
        [
            "--session", session, "terminal", "session", "control", pane, "--takeover",
            "--cols", HerdrTerminalBridgeSpecification.columnsToken,
            "--rows", HerdrTerminalBridgeSpecification.rowsToken,
        ]
    }

    public static func remoteShellLine(
        session: String, pane: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        remoteHerdrCommand(
            arguments: arguments(session: session, pane: pane), platform: platform)
    }
}

public func remoteHerdrCommand(
    arguments: [String], platform: RemoteMachinePlatform
) -> String {
    let words = ["herdr"] + arguments
    if platform == .windows {
        return PowerShell.command(PowerShell.invocation(words) ?? "herdr")
    }
    let command = words.map(ShellQuote.quote).joined(separator: " ")
    return "export PATH=\"\(HerdrCollector.pathPrefix)\"; \(command)"
}
