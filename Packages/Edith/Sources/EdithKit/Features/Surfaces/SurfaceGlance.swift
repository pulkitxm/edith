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

public struct SurfaceGlance: Equatable, Sendable {
    public var source: SurfaceGlanceSource
    public var icon: String
    public var value: String
    public var detail: String
    public var urgency: Int
    public var tab: SurfaceNotchTab
}

public struct SurfaceGlanceContext: Sendable {
    public var agents: AgentActivityPresentation
    public var observing: Bool
    public var monitoringStalls: Bool
    public var hasMusic: Bool
    public var playingMusic: Bool
    public var files: Int
    public var now: Date
    public var focus: AttentionFocusSession?
    public var quotaRemaining: Double?
    public var nextMeeting: Date?

    public init(
        agents: AgentActivityPresentation, observing: Bool, monitoringStalls: Bool,
        hasMusic: Bool = false, playingMusic: Bool = false, files: Int = 0,
        now: Date = Date(), focus: AttentionFocusSession? = nil,
        quotaRemaining: Double? = nil, nextMeeting: Date? = nil
    ) {
        self.agents = agents
        self.observing = observing
        self.monitoringStalls = monitoringStalls
        self.hasMusic = hasMusic
        self.playingMusic = playingMusic
        self.files = files
        self.now = now
        self.focus = focus
        self.quotaRemaining = quotaRemaining
        self.nextMeeting = nextMeeting
    }

    public func resolve(_ source: SurfaceGlanceSource, leading: Bool) -> SurfaceGlance? {
        let selected: SurfaceGlanceSource
        if source == .automatic {
            if !agents.approvals.isEmpty || agents.active > 0 {
                if leading {
                    selected = agents.working > 0 ? .workingAgents : .activeAgents
                } else if !agents.approvals.isEmpty {
                    selected = .permissions
                } else if agents.waiting > 0 {
                    selected = .waitingAgents
                } else if agents.stuck > 0 {
                    selected = .stuckAgents
                } else if agents.errors > 0 {
                    selected = .failedAgents
                } else if agents.quiet > 0 {
                    selected = .quietAgents
                } else {
                    selected = hasMusic ? .music : .activeAgents
                }
            } else if hasMusic {
                selected = .music
            } else if focus != nil {
                selected = leading ? .focus : .clock
            } else if files > 0 {
                selected = leading ? .files : .clock
            } else {
                return nil
            }
        } else {
            selected = source
        }
        switch selected {
        case .none, .automatic: return nil
        case .workingAgents:
            return count(
                selected, "terminal.fill", agents.working, "Working agents", enabled: observing)
        case .waitingAgents:
            return count(
                selected, "hand.raised.fill", agents.waiting, "Agents need your input",
                enabled: observing, urgency: agents.waiting > 0 ? 1 : 0)
        case .stuckAgents:
            return count(
                selected, "exclamationmark.triangle.fill", agents.stuck, "Confirmed stalled agents",
                enabled: monitoringStalls, urgency: agents.stuck > 0 ? 2 : 0)
        case .activeAgents:
            return count(
                selected, "square.stack.3d.up.fill", agents.active, "Active sessions",
                enabled: observing)
        case .quietAgents:
            return count(
                selected, "antenna.radiowaves.left.and.right.slash", agents.quiet,
                "Agents with no recent signal", enabled: observing)
        case .failedAgents:
            return count(
                selected, "exclamationmark.circle.fill", agents.errors, "Agent errors",
                enabled: observing, urgency: agents.errors > 0 ? 2 : 0)
        case .permissions:
            return count(
                selected, "hand.raised.fill", agents.approvals.count, "One-use permission requests",
                enabled: observing, urgency: agents.approvals.isEmpty ? 0 : 1)
        case .music:
            guard hasMusic else { return nil }
            return SurfaceGlance(
                source: selected, icon: playingMusic ? "waveform" : "pause.fill", value: "",
                detail: "Now playing", urgency: 0, tab: .home)
        case .files:
            return SurfaceGlance(
                source: selected, icon: "tray.full.fill", value: String(files),
                detail: "Shelf files", urgency: 0, tab: .files)
        case .clock:
            return SurfaceGlance(
                source: selected, icon: "clock", value: now.formatted(.dateTime.hour().minute()),
                detail: "Local time", urgency: 0, tab: .home)
        case .focus:
            let remaining = focus.map {
                max(0, $0.plannedDuration - now.timeIntervalSince($0.startedAt))
            }
            return SurfaceGlance(
                source: selected, icon: "timer",
                value: remaining.map { Self.minutes($0) } ?? "Idle",
                detail: focus?.name ?? "Focus timer", urgency: remaining == 0 ? 1 : 0, tab: .home)
        case .limits:
            return SurfaceGlance(
                source: selected, icon: "gauge",
                value: quotaRemaining.flatMap {
                    $0.isFinite ? "\(Int(max(0, min(100, $0))))%" : nil
                } ?? "?", detail: "Lowest remaining quota",
                urgency: (quotaRemaining ?? 100) <= 10 ? 1 : 0, tab: .home)
        case .nextMeeting:
            return SurfaceGlance(
                source: selected, icon: "calendar",
                value: nextMeeting.map { Self.minutes(max(0, $0.timeIntervalSince(now))) }
                    ?? "Free", detail: "Next meeting", urgency: 0, tab: .home)
        }
    }

    private func count(
        _ source: SurfaceGlanceSource, _ icon: String, _ value: Int,
        _ detail: String, enabled: Bool, urgency: Int = 0
    ) -> SurfaceGlance {
        SurfaceGlance(
            source: source, icon: icon, value: enabled ? String(value) : "Off",
            detail: detail, urgency: urgency, tab: .agents)
    }

    private static func minutes(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "?" }
        let total = Int(seconds)
        if total >= 3600 { return "\(total / 3600)h \(total % 3600 / 60)m" }
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
