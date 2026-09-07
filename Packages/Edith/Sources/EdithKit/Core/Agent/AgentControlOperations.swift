import EdithCore
import Foundation

public enum AgentControlOperation: String, CaseIterable, Sendable {
    case status
    case jobs
    case restart
    case logs
    case events
    case run
    case cancel

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
        case .events:
            descriptor("agent.events", "Read retained background events.", "events", .read)
        case .run:
            descriptor("agent.run", "Run a background job now.", "run", .write)
        case .cancel:
            descriptor("agent.cancel", "Cancel a background job.", "cancel", .write)
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
        case .events:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Background agent settings", action: "read the event timeline")
            ])
        case .run, .cancel:
            .userInterface([
                UserInterfaceActionPlacement(
                    surface: "Background agent settings", action: rawValue + " a job",
                    exampleArguments: ["usage.refresh"])
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
