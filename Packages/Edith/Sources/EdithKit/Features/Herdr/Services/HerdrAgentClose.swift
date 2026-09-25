import Foundation

public enum HerdrAgentCloseCommand {
    public static func arguments(for agent: HerdrAgent) -> [String] {
        ["--session", agent.session, "agent", "send-keys", agent.pane, "ctrl+c", "ctrl+c"]
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
    public var interrupt: @Sendable () async throws -> Void
    public var state: @Sendable () async throws -> HerdrPaneState
    public var closePane: @Sendable () async throws -> Void

    public init(
        interrupt: @escaping @Sendable () async throws -> Void,
        state: @escaping @Sendable () async throws -> HerdrPaneState,
        closePane: @escaping @Sendable () async throws -> Void
    ) {
        self.interrupt = interrupt
        self.state = state
        self.closePane = closePane
    }
}

public enum HerdrAgentCloseExecution {
    public static let attempts = 2

    public static func close(_ agent: HerdrAgent) async throws {
        let machine = try machine(for: agent)
        let arguments = HerdrAgentCloseCommand.arguments(for: agent)
        try await close(
            steps: HerdrAgentCloseSteps(
                interrupt: { _ = try await HerdrCommand.run(arguments, timeout: 10, on: machine) },
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
        steps: HerdrAgentCloseSteps, patience: Duration = .seconds(4),
        interval: Duration = .milliseconds(250)
    ) async throws {
        for _ in 0..<attempts {
            if case .missing? = try? await steps.state() { return }
            try? await steps.interrupt()
            let exited = await HerdrPaneOperations.waitForShell(
                timeout: patience, interval: interval, state: steps.state)
            if exited { break }
        }
        try await steps.closePane()
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
