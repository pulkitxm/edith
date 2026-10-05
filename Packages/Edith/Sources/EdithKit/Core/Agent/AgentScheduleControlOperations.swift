import EdithCore
import Foundation

public enum AgentScheduleControlOperation: String, CaseIterable, Sendable {
    case add
    case list = "ls"
    case remove = "rm"
    case enable
    case disable
    case run

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .add:
            descriptor("agent.schedule.add", "Schedule a command in the background agent.", .write)
        case .list:
            descriptor(
                "agent.schedule.list", "List the commands the agent runs on a schedule.", .read)
        case .remove:
            descriptor("agent.schedule.remove", "Remove a scheduled command.", .write)
        case .enable:
            descriptor("agent.schedule.enable", "Resume a paused scheduled command.", .write)
        case .disable:
            descriptor("agent.schedule.disable", "Pause a scheduled command.", .write)
        case .run:
            descriptor("agent.schedule.run", "Run a scheduled command now.", .write)
        }
    }

    public var interfaceExposure: UserOperationExposure {
        .commandLineOnly(
            reason:
                "Schedules are authored by scripts and agents with a command line and a cron expression."
        )
    }

    private func descriptor(
        _ id: String, _ summary: String, _ effect: UserOperationEffect
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: id), summary: summary,
            cli: ["agent", "schedule", rawValue], effect: effect)
    }
}
