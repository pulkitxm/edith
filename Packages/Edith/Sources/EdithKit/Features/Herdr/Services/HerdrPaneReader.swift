import Foundation

public struct HerdrAttentionProbe: Equatable, Sendable {
    public var agent: HerdrAgent
    public var countChanges: Bool
    public var readsExplain: Bool

    public init(agent: HerdrAgent, countChanges: Bool, readsExplain: Bool = true) {
        self.agent = agent
        self.countChanges = countChanges
        self.readsExplain = readsExplain
    }
}

public enum HerdrPaneReader {
    public static let visibleLines = 40
    public static let timeout: TimeInterval = 12
    public static let outputLimit = 262_144

    public static func readArguments(for agent: HerdrAgent) -> [String] {
        [
            "--session", agent.session, "pane", "read", agent.pane, "--source", "visible",
            "--lines", String(visibleLines),
        ]
    }

    public static func explainArguments(for agent: HerdrAgent) -> [String] {
        ["--session", agent.session, "agent", "explain", agent.pane, "--json"]
    }

    public static func inspect(
        _ probes: [HerdrAttentionProbe], quinjet: QuinjetClient = .live
    ) async -> [String: HerdrAttentionEvidence] {
        guard let first = probes.first?.agent else { return [:] }
        if first.machineIsLocal {
            guard let executable = HerdrCollector.executable() else { return [:] }
            return await collect(probes) { arguments in
                await runLocal(executable, arguments)
            } changes: { path in
                try? await quinjet.changeCount(at: path)
            }
        }
        guard
            let machine = MachineRegistry.machines().first(where: {
                $0.id.uuidString == first.machineID
            })
        else { return [:] }
        let connection = SSHConnection(machine: machine, controlSocketMode: .isolated)
        guard (try? await connection.connect()) != nil else { return [:] }
        let platform = await connection.remotePlatform ?? .linux
        let remote =
            probes.contains(where: \.countChanges)
            ? try? await QuinjetRemote.connected(
                machineID: machine.id, machineName: machine.name, target: machine.sshTarget,
                connection: connection) : nil
        let evidence = await collect(probes) { arguments in
            let command = remoteHerdrCommand(arguments: arguments, platform: platform)
            guard let result = try? await connection.run(command, timeout: timeout),
                result.status == 0
            else { return nil }
            return result.stdoutText
        } changes: { path in
            guard let remote else { return nil }
            return try? await quinjet.changeCount(at: path, remote: remote)
        }
        await connection.disconnect()
        return evidence
    }

    static func collect(
        _ probes: [HerdrAttentionProbe], run: (_ arguments: [String]) async -> String?,
        changes: (_ path: String) async -> Int?
    ) async -> [String: HerdrAttentionEvidence] {
        var evidence: [String: HerdrAttentionEvidence] = [:]
        for probe in probes {
            let agent = probe.agent
            let screen = await run(readArguments(for: agent)).map { text in
                HerdrPaneScreen(raw: text, explain: nil)
            }
            var item = HerdrAttentionEvidence(screen: screen)
            if probe.readsExplain, item.screen != nil,
                let explain = await run(explainArguments(for: agent))
            {
                item.screen?.explain = HerdrAgentExplain.parse(explain)
            }
            if probe.countChanges, !agent.cwd.isEmpty { item.changes = await changes(agent.cwd) }
            evidence[agent.id] = item
        }
        return evidence
    }

    private static func runLocal(_ executable: URL, _ arguments: [String]) async -> String? {
        let request = CLICommandRequest(
            executableURL: executable, arguments: arguments,
            environment: CLIToolEnvironment.sanitized(), timeout: timeout,
            maximumOutputBytes: outputLimit, discardsStandardError: true)
        guard let result = try? await CLICommandRunner.run(request, onLine: { _ in }),
            result.terminationStatus == 0
        else { return nil }
        return result.standardOutput
    }
}
