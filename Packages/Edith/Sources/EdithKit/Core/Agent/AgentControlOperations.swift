import EdithCore
import Foundation

public enum AgentControlOperation: String, CaseIterable, Sendable {
    case status
    case jobs
    case restart
    case logs

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .status:
            descriptor("agent.status", "Read the background agent's live state.", "status", .read)
        case .jobs:
            descriptor("agent.jobs", "List the jobs the background agent runs.", "jobs", .read)
        case .restart:
            descriptor(
                "agent.restart", "Restart the background agent.", "restart", .write)
        case .logs:
            descriptor("agent.logs", "Read recent background agent log lines.", "logs", .read)
        }
    }

    public var interfaceExposure: UserOperationExposure {
        switch self {
        case .status:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Background agent settings", action: "read the agent's live state")
            ])
        case .jobs:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Background agent settings", action: "read the live job table")
            ])
        case .restart:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Background agent settings", action: "restart the agent")
            ])
        case .logs:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Background agent settings", action: "open the agent log")
            ])
        }
    }

    private func descriptor(
        _ id: String, _ summary: String, _ command: String, _ effect: UserOperationEffect
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: id), summary: summary, cli: ["agent", command],
            effect: effect)
    }
}
