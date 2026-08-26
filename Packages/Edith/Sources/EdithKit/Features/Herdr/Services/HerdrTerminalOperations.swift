import Foundation

public enum HerdrMachineTerminal {
    public static let title = "Herdr Terminal"

    public static func id(machineID: String) -> String { "\(machineID)|terminal" }

    public static func agent(for host: HerdrHostSnapshot) -> HerdrAgent {
        HerdrAgent(
            id: id(machineID: host.id), machineID: host.id, machineName: host.name,
            machineIsLocal: host.isLocal, sshTarget: host.sshTarget, session: "",
            pane: "", kind: HerdrKind.terminalLabel, status: .unknown, title: title,
            workspace: "", cwd: "", category: .terminal)
    }

    public static func arguments(for agent: HerdrAgent) -> [String] {
        guard !agent.machineIsLocal, let target = agent.sshTarget, !target.isEmpty else {
            return []
        }
        return ["--remote", target]
    }

    public static func line(for agent: HerdrAgent) -> String {
        (["herdr"] + arguments(for: agent)).joined(separator: " ")
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
}
