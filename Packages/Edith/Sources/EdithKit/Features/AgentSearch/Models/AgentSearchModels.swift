import Foundation

public enum AgentTranscriptKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case pi

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .pi: "Pi"
        }
    }

    public init?(herdrKind: String) {
        switch HerdrKind.displayName(for: herdrKind) {
        case "Claude Code": self = .claude
        case "Codex": self = .codex
        case "Pi": self = .pi
        default: return nil
        }
    }

    public func resume(sessionID: String, path: String) -> AgentSessionResume {
        switch self {
        case .claude: AgentSessionResume(leading: [], trailing: ["--resume", sessionID])
        case .codex: AgentSessionResume(leading: ["resume", sessionID], trailing: [])
        case .pi: AgentSessionResume(leading: [], trailing: ["--session", path])
        }
    }
}

public struct AgentSessionResume: Sendable, Equatable {
    public var leading: [String]
    public var trailing: [String]

    public init(leading: [String], trailing: [String]) {
        self.leading = leading
        self.trailing = trailing
    }

    public func wrapping(_ arguments: [String]) -> [String] {
        leading + arguments + trailing
    }
}

public enum AgentSearchOperation {
    public static let search = "sessions.search"
    public static let internalOperations = [search]
}

public struct AgentSearchRequest: Codable, Sendable, Equatable {
    public static let defaultLimit = 12

    public var query: String
    public var machineID: String
    public var limit: Int
    public var budget: Double

    public init(
        query: String, machineID: String = HerdrHostSnapshot.localID,
        limit: Int = AgentSearchRequest.defaultLimit, budget: Double = 1.5
    ) {
        self.query = query
        self.machineID = machineID
        self.limit = limit
        self.budget = budget
    }
}

public struct AgentSearchHit: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var machineID: String
    public var kind: AgentTranscriptKind
    public var sessionID: String
    public var path: String
    public var cwd: String
    public var branch: String?
    public var pullRequest: String?
    public var title: String
    public var snippet: String
    public var summary: String
    public var lastActivity: Double?
    public var score: Double
    public var placeRank: Int

    public init(
        machineID: String, kind: AgentTranscriptKind, sessionID: String, path: String,
        cwd: String, branch: String? = nil, pullRequest: String? = nil, title: String,
        snippet: String, summary: String, lastActivity: Double?, score: Double,
        placeRank: Int
    ) {
        id = "\(machineID)|\(kind.rawValue)|\(sessionID)"
        self.machineID = machineID
        self.kind = kind
        self.sessionID = sessionID
        self.path = path
        self.cwd = cwd
        self.branch = branch
        self.pullRequest = pullRequest
        self.title = title
        self.snippet = snippet
        self.summary = summary
        self.lastActivity = lastActivity
        self.score = score
        self.placeRank = placeRank
    }

    public var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    public var resume: AgentSessionResume {
        kind.resume(sessionID: sessionID, path: path)
    }

    public var lastActivityDate: Date? {
        lastActivity.map { Date(timeIntervalSince1970: $0) }
    }

    public func assigning(machineID: String) -> AgentSearchHit {
        AgentSearchHit(
            machineID: machineID, kind: kind, sessionID: sessionID, path: path, cwd: cwd,
            branch: branch, pullRequest: pullRequest, title: title, snippet: snippet,
            summary: summary, lastActivity: lastActivity, score: score, placeRank: placeRank)
    }
}

public struct AgentSearchReply: Codable, Sendable, Equatable {
    public var machineID: String
    public var hits: [AgentSearchHit]
    public var indexed: Int
    public var pending: Int
    public var error: String?
    public var milliseconds: Int

    public init(
        machineID: String, hits: [AgentSearchHit] = [], indexed: Int = 0, pending: Int = 0,
        error: String? = nil, milliseconds: Int = 0
    ) {
        self.machineID = machineID
        self.hits = hits
        self.indexed = indexed
        self.pending = pending
        self.error = error
        self.milliseconds = milliseconds
    }
}
