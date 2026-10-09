import Foundation

public struct CodeStatsReportQuery: Codable, Sendable {
    public let range: CodeStatsRange
    public let filter: CodeStatsFilter
    public init(_ range: CodeStatsRange, filter: CodeStatsFilter = .default) {
        self.range = range; self.filter = filter
    }
}

public enum CodeStatsAgentOperation {
    public static let run = "codestats.run"
    public static let status = "codestats.status"
    public static let report = "codestats.report"
    public static let authors = "codestats.authors"
    public static let start = "codestats.start"
    public static let cancel = "codestats.cancel"
    public static let profile = "codestats.profile"
    public static let facts = "codestats.facts"
    public static let audit = "codestats.audit"
    public static let scheduleJob = "codestats.schedule"
    public static let internalOperations = [
        status, report, authors, start, cancel, profile, facts, audit,
    ]
}

public struct CodeStatsAgentClient: Sendable {
    public typealias Perform = @Sendable (String, Data, TimeInterval) async throws -> Data

    public static let authorsTimeout: TimeInterval = 600
    public static let reportTimeout: TimeInterval = 30
    public static let profileTimeout: TimeInterval = 120

    private let perform: Perform

    public init(
        perform: @escaping Perform = {
            try await AgentClient.shared.performInternalAsync($0, payload: $1, timeout: $2)
        }
    ) {
        self.perform = perform
    }

    public func status() async throws -> CodeStatsStatus {
        try await request(CodeStatsStatus.self, CodeStatsAgentOperation.status)
    }

    public func report(_ range: CodeStatsRange, filter: CodeStatsFilter = .default) async throws
        -> CodeStatsReport?
    {
        try await request(
            CodeStatsReport?.self, CodeStatsAgentOperation.report,
            AgentPayload.encode(CodeStatsReportQuery(range, filter: filter)),
            timeout: Self.reportTimeout)
    }

    public func facts() async throws -> CodeStatsFactTable? {
        try await request(
            CodeStatsFactTable?.self, CodeStatsAgentOperation.facts,
            timeout: Self.reportTimeout)
    }

    public func audit(_ filter: CodeStatsFilter = .default) async throws -> CodeStatsAudit? {
        try await request(
            CodeStatsAudit?.self, CodeStatsAgentOperation.audit, AgentPayload.encode(filter),
            timeout: Self.reportTimeout)
    }

    public func authors() async throws -> [CodeStatsDiscoveredAuthor] {
        try await request(
            [CodeStatsDiscoveredAuthor].self, CodeStatsAgentOperation.authors,
            timeout: Self.authorsTimeout)
    }

    public func start() async throws -> CodeStatsActiveRun {
        try await request(
            CodeStatsActiveRun.self, CodeStatsAgentOperation.start,
            AgentPayload.encode(CodeStatsTrigger.manual))
    }

    public func profile() async throws -> CodeStatsProfileLookup {
        try await request(
            CodeStatsProfileLookup.self, CodeStatsAgentOperation.profile,
            timeout: Self.profileTimeout)
    }

    public func cancel() async throws -> CodeStatsStatus {
        try await request(CodeStatsStatus.self, CodeStatsAgentOperation.cancel)
    }

    private func request<Value: Decodable>(
        _ type: Value.Type, _ operation: String, _ payload: Data = Data(),
        timeout: TimeInterval = AgentClient.replyTimeout
    ) async throws -> Value {
        try AgentPayload.decode(type, from: await perform(operation, payload, timeout))
    }
}
