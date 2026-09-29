import Foundation

public enum HerdrAgentCloseCommand {
    public static func arguments(for agent: HerdrAgent) -> [String] {
        HerdrSessionCommand.scoped(
            ["pane", "send-keys", agent.pane, "ctrl+c"], session: agent.session)
    }

    public static func shellLine(
        for agent: HerdrAgent, platform: RemoteMachinePlatform = .linux
    ) -> String {
        remoteHerdrCommand(arguments: arguments(for: agent), platform: platform)
    }
}

public enum HerdrAgentCloseError: LocalizedError, Equatable {
    case machineUnavailable

    public var errorDescription: String? {
        "The agent's machine is no longer configured."
    }
}

public struct HerdrAgentCloseSteps: Sendable {
    public var preserveSpace: @Sendable () async throws -> Void
    public var interrupt: @Sendable () async throws -> Void
    public var state: @Sendable () async throws -> HerdrPaneState
    public var closePane: @Sendable () async throws -> Void

    public init(
        preserveSpace: @escaping @Sendable () async throws -> Void,
        interrupt: @escaping @Sendable () async throws -> Void,
        state: @escaping @Sendable () async throws -> HerdrPaneState,
        closePane: @escaping @Sendable () async throws -> Void
    ) {
        self.preserveSpace = preserveSpace
        self.interrupt = interrupt
        self.state = state
        self.closePane = closePane
    }
}

public enum HerdrAgentCloseExecution {
    private static let gate = HerdrTerminalSpaceGate()
    public static let attempts = 2
    public static let pressGap = Duration.milliseconds(250)

    public static func close(_ agent: HerdrAgent) async throws {
        let machine = try machine(for: agent)
        let key = "\(agent.machineID)|\(agent.session)"
        try await gate.run(key) {
            try await close(agent, on: machine)
        }
    }

    private static func close(_ agent: HerdrAgent, on machine: Machine?) async throws {
        let arguments = HerdrAgentCloseCommand.arguments(for: agent)
        try await close(
            steps: HerdrAgentCloseSteps(
                preserveSpace: {
                    try await preserveSpace(for: agent) { arguments in
                        try await HerdrCommand.run(arguments, timeout: 10, on: machine)
                    }
                },
                interrupt: {
                    _ = try await HerdrCommand.run(arguments, timeout: 10, on: machine)
                    try await Task.sleep(for: pressGap)
                    _ = try await HerdrCommand.run(arguments, timeout: 10, on: machine)
                },
                state: {
                    try await HerdrPaneOperations.state(
                        session: agent.session, pane: agent.pane, on: machine)
                },
                closePane: {
                    try await HerdrPaneOperations.close(
                        session: agent.session, pane: agent.pane, on: machine)
                }))
    }

    public static func close(
        steps: HerdrAgentCloseSteps, patience: Duration = .seconds(3),
        interval: Duration = .milliseconds(250)
    ) async throws {
        if case .missing = try await steps.state() { return }
        try await steps.preserveSpace()
        for _ in 0..<attempts {
            if case .missing? = try? await steps.state() { return }
            try? await steps.interrupt()
            let exited = await HerdrPaneOperations.waitForShell(
                timeout: patience, interval: interval, state: steps.state)
            if exited { break }
        }
        try await steps.closePane()
    }

    static func preserveSpace(
        for agent: HerdrAgent,
        run: @Sendable ([String]) async throws -> String
    ) async throws {
        let snapshot = try await run(
            HerdrSessionCommand.scoped(["api", "snapshot"], session: agent.session))
        guard let board = HerdrListParser.snapshotBoard(from: snapshot), board.hasPaneList else {
            throw HerdrCommandError.malformedResponse
        }
        guard let pane = board.panes.first(where: { $0.pane == agent.pane }) else { return }
        guard let workspace = pane.workspaceID, !workspace.isEmpty else {
            throw HerdrCommandError.malformedResponse
        }
        guard board.panes.filter({ $0.workspaceID == workspace }).count == 1 else { return }
        let output = try await run(
            HerdrSessionCommand.scoped(
                HerdrTabCreateCommand.arguments(workspaceID: workspace, cwd: pane.cwd ?? agent.cwd),
                session: agent.session))
        guard let created = HerdrListParser.createdPane(from: output),
            created.workspaceID == workspace, created.paneID != agent.pane
        else { throw HerdrCommandError.malformedResponse }
    }

    private static func machine(for agent: HerdrAgent) throws -> Machine? {
        guard !agent.machineIsLocal else { return nil }
        guard
            let machine = MachineRegistry.machines().first(where: {
                $0.id.uuidString == agent.machineID
            })
        else { throw HerdrAgentCloseError.machineUnavailable }
        return machine
    }
}
