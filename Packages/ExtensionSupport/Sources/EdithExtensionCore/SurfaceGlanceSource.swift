import Foundation

public enum SurfaceGlanceSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, workingAgents, waitingAgents, stuckAgents, activeAgents, quietAgents,
        failedAgents, permissions
    case music, files, clock, focus, limits, nextMeeting, none
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .workingAgents: "Working agents"
        case .waitingAgents: "Agents needing you"
        case .stuckAgents: "Stuck agents"
        case .activeAgents: "Active sessions"
        case .quietAgents: "Agents with no recent signal"
        case .failedAgents: "Agent errors"
        case .permissions: "Pending permissions"
        case .music: "Now playing"
        case .files: "Shelf files"
        case .clock: "Local clock"
        case .focus: "Focus countdown"
        case .limits: "Lowest remaining quota"
        case .nextMeeting: "Next meeting"
        case .none: "Hidden"
        }
    }
}
