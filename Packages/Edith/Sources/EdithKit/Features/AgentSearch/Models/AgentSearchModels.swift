import Foundation

public enum AgentTranscriptKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case pi
    case opencode

    public init?(herdrKind: String) {
        switch HerdrKind.displayName(for: herdrKind) {
        case "Claude Code": self = .claude
        case "Codex": self = .codex
        case "Pi": self = .pi
        case "OpenCode": self = .opencode
        default: return nil
        }
    }
}

public enum AgentSearchSource: String, Codable, Sendable {
    case transcript
    case terminal
    case none
}

public enum AgentSearchOperation {
    public static let search = "sessions.search"
    public static let internalOperations = [search]
}

public struct AgentSearchTarget: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var session: String
    public var pane: String
    public var cwd: String
    public var title: String

    public init(
        id: String, kind: String, session: String, pane: String, cwd: String, title: String
    ) {
        self.id = id
        self.kind = kind
        self.session = session
        self.pane = pane
        self.cwd = cwd
        self.title = title
    }

    public init(agent: HerdrAgent) {
        self.init(
            id: agent.id, kind: agent.kind, session: agent.session, pane: agent.pane,
            cwd: agent.cwd, title: agent.title)
    }
}

public struct AgentSearchRequest: Codable, Sendable, Equatable {
    public var query: String
    public var machineID: String
    public var targets: [AgentSearchTarget]
    public var budget: Double

    public init(
        query: String, machineID: String = HerdrHostSnapshot.localID,
        targets: [AgentSearchTarget], budget: Double = 1.5
    ) {
        self.query = query
        self.machineID = machineID
        self.targets = targets
        self.budget = budget
    }
}

public struct AgentSearchHit: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var source: AgentSearchSource
    public var sessionID: String?
    public var title: String
    public var snippet: String
    public var summary: String
    public var lastActivity: Double?
    public var score: Double

    public init(
        id: String, source: AgentSearchSource, sessionID: String? = nil, title: String,
        snippet: String, summary: String, lastActivity: Double?, score: Double
    ) {
        self.id = id
        self.source = source
        self.sessionID = sessionID
        self.title = title
        self.snippet = snippet
        self.summary = summary
        self.lastActivity = lastActivity
        self.score = score
    }

    public var lastActivityDate: Date? {
        lastActivity.map { Date(timeIntervalSince1970: $0) }
    }
}

public struct AgentSearchReply: Codable, Sendable, Equatable {
    public var machineID: String
    public var hits: [AgentSearchHit]
    public var pending: Int
    public var error: String?
    public var milliseconds: Int

    public init(
        machineID: String, hits: [AgentSearchHit] = [], pending: Int = 0, error: String? = nil,
        milliseconds: Int = 0
    ) {
        self.machineID = machineID
        self.hits = hits
        self.pending = pending
        self.error = error
        self.milliseconds = milliseconds
    }
}
