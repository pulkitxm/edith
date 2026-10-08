import Foundation

public enum HerdrMachineTerminal {
    public static let title = "Herdr Terminal"

    public static func id(machineID: String) -> String { "\(machineID)|terminal" }

    public static func agent(for host: HerdrHostSnapshot, session: String = "") -> HerdrAgent {
        let session = session == "default" ? "" : session
        return HerdrAgent(
            id: id(machineID: host.id) + (session.isEmpty ? "" : "|\(session)"), machineID: host.id,
            machineName: host.name,
            machineIsLocal: host.isLocal, sshTarget: host.sshTarget, session: session,
            pane: "", kind: HerdrKind.terminalLabel, status: .unknown,
            title: session.isEmpty ? title : "\(title) · \(session)",
            workspace: "", cwd: "", category: .terminal)
    }

    public static func arguments(for agent: HerdrAgent) -> [String] {
        let session = agent.session.isEmpty ? [] : ["--session", agent.session]
        guard !agent.machineIsLocal, let target = agent.sshTarget, !target.isEmpty else {
            return session
        }
        return ["--remote", target] + session
    }

    public static func line(for agent: HerdrAgent) -> String {
        (["herdr"] + arguments(for: agent)).map(ShellQuote.quote).joined(separator: " ")
    }

    public static func shellLine(for agent: HerdrAgent) -> String {
        "export PATH=\"\(HerdrCollector.pathPrefix)\"; \(line(for: agent))"
    }

    public static let nestingVariables = [
        "HERDR_ENV", "HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID",
    ]

    public static func unnested(_ environment: [String]) -> [String] {
        let cleared = environment.filter { entry in
            guard let split = entry.firstIndex(of: "=") else { return true }
            return !nestingVariables.contains(String(entry[entry.startIndex..<split]))
        }
        return cleared + nestingVariables.map { "\($0)=" }
    }

    public static func launchRequest(
        for agent: HerdrAgent, environment: [String],
        executable: URL? = HerdrCollector.executable()
    ) -> TerminalLaunchRequest {
        let clean = unnested(environment)
        guard let executable else {
            return TerminalLaunchRequest(
                executable: "/bin/zsh", arguments: ["-c", shellLine(for: agent)],
                environment: clean)
        }
        return TerminalLaunchRequest(
            executable: executable.path, arguments: arguments(for: agent),
            environment: clean)
    }

    public static func windowsLaunchRequest(
        connection: SSHConnection, environment: [String], session: String = ""
    ) -> TerminalLaunchRequest {
        TerminalLaunchRequest(
            executable: SSHConnection.executable.path,
            arguments: connection.terminalArguments(
                remoteCommand: remoteHerdrCommand(
                    arguments: session.isEmpty ? [] : ["--session", session],
                    platform: .windows, interactive: true)),
            environment: unnested(environment + connection.terminalEnvironment()))
    }
}
