import Foundation

public struct AgentTranscriptDigest: Codable, Sendable, Equatable {
    public static let titleLimit = 80

    public var path: String
    public var kind: AgentTranscriptKind
    public var sessionID: String
    public var cwd: String
    public var branch: String?
    public var pullRequest: String?
    public var namedTitle: String?
    public var prompts: [String]
    public var replies: [String]
    public var firstActivity: Double?
    public var lastActivity: Double?
    public var offset: UInt64
    public var size: UInt64
    public var modified: Double

    public init(path: String, kind: AgentTranscriptKind, sessionID: String = "") {
        self.path = path
        self.kind = kind
        self.sessionID = sessionID
        cwd = ""
        prompts = []
        replies = []
        offset = 0
        size = 0
        modified = 0
    }

    public var title: String {
        if let namedTitle, !namedTitle.isEmpty { return namedTitle }
        if let first = prompts.first { return String(first.prefix(Self.titleLimit)) }
        return "Session \(sessionID.prefix(8))"
    }

    public var summary: String {
        guard let first = prompts.first else { return "" }
        let opening = String(first.prefix(160))
        guard prompts.count > 1, let last = prompts.last else { return opening }
        return opening + " … " + String(last.prefix(160))
    }

    mutating func addPrompt(_ raw: String) {
        let text = Self.clean(raw)
        guard !text.isEmpty, prompts.last != text else { return }
        prompts.append(text)
    }

    mutating func addReply(_ raw: String) {
        let text = Self.clean(raw)
        guard !text.isEmpty, replies.last != text else { return }
        replies.append(text)
    }

    mutating func touch(_ timestamp: Double?) {
        guard let timestamp else { return }
        firstActivity = min(firstActivity ?? timestamp, timestamp)
        lastActivity = max(lastActivity ?? timestamp, timestamp)
    }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clean(_ text: String, limit: Int) -> String {
        String(clean(text).prefix(limit))
    }
}
