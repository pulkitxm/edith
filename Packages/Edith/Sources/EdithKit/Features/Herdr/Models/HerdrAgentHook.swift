import Foundation

public enum HerdrHookOperation {
    public static let list = "sessions.hooks.list"
    public static let arm = "sessions.hooks.arm"
    public static let remove = "sessions.hooks.remove"
    public static let internalOperations = [list, arm, remove]
}

public enum HerdrHookPhase: String, Codable, Sendable {
    case armed
    case sending
    case sent
    case skipped
    case cancelled

    public var settled: Bool { self == .sent || self == .skipped || self == .cancelled }
}

public struct HerdrAgentHook: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var agentID: String
    public var machineID: String
    public var machineIsLocal: Bool
    public var session: String
    public var pane: String
    public var kind: String
    public var title: String
    public var message: String
    public var identity: HerdrAgentIdentity
    public var createdAt: Date
    public var baselineSequence: Int?
    public var ran: Bool
    public var phase: HerdrHookPhase
    public var detail: String?
    public var settledAt: Date?

    public init(
        id: UUID = UUID(), agent: HerdrAgent, message: String,
        observation: HerdrAgentObservation, createdAt: Date = Date()
    ) {
        self.id = id
        agentID = agent.id
        machineID = agent.machineID
        machineIsLocal = agent.machineIsLocal
        session = agent.session
        pane = agent.pane
        kind = agent.kind
        title = agent.title
        self.message = message
        identity = observation.identity
        self.createdAt = createdAt
        baselineSequence = observation.sequence
        ran = observation.status == .working || observation.status == .blocked
        phase = .armed
    }

    public var isArmed: Bool { phase == .armed }

    public mutating func settle(_ phase: HerdrHookPhase, _ detail: String, at date: Date) {
        self.phase = phase
        self.detail = detail
        settledAt = date
    }
}

public struct HerdrHooksSnapshot: Codable, Equatable, Sendable {
    public var hooks: [HerdrAgentHook]

    public init(hooks: [HerdrAgentHook] = []) {
        self.hooks = hooks
    }

    public func armed(for agentID: String) -> HerdrAgentHook? {
        hooks.first { $0.agentID == agentID && !$0.phase.settled }
    }

    public func latestSettled(for agentID: String) -> HerdrAgentHook? {
        hooks.filter { $0.agentID == agentID && $0.phase.settled }
            .max { ($0.settledAt ?? $0.createdAt) < ($1.settledAt ?? $1.createdAt) }
    }
}

public struct HerdrHookArmRequest: Codable, Equatable, Sendable {
    public var agent: HerdrAgent
    public var message: String

    public init(agent: HerdrAgent, message: String) {
        self.agent = agent
        self.message = message
    }
}

public enum HerdrHookDecision: Equatable, Sendable {
    case keep(HerdrAgentHook)
    case fire(HerdrAgentHook)
    case cancel(String)
}

public enum HerdrHookEvaluator {
    public static let goneReason = "The agent closed before it finished."
    public static let replacedReason = "A different agent took over the pane."

    public static func evaluate(_ hook: HerdrAgentHook, _ probe: HerdrAgentProbe)
        -> HerdrHookDecision
    {
        switch probe {
        case .unreachable:
            return .keep(hook)
        case .gone:
            return .cancel(goneReason)
        case .agent(let observation):
            guard
                observation.identity == hook.identity,
                HerdrKind.displayName(for: observation.kind)
                    == HerdrKind.displayName(
                        for: hook.kind)
            else { return .cancel(replacedReason) }
            var next = hook
            let moved =
                observation.sequence != nil && hook.baselineSequence != nil
                && observation.sequence != hook.baselineSequence
            switch observation.status {
            case .working, .blocked:
                next.ran = true
            case .done where next.ran || moved:
                return .fire(next)
            case .idle where next.ran:
                return .fire(next)
            case .done, .idle, .unknown:
                break
            }
            if observation.status != .unknown {
                next.baselineSequence = observation.sequence ?? next.baselineSequence
            }
            return .keep(next)
        }
    }
}
