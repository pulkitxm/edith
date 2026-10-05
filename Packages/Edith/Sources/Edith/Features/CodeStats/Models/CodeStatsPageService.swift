import EdithKit
import Foundation

struct CodeStatsPageService: Sendable {
    var status: @Sendable () async throws -> CodeStatsStatus
    var report: @Sendable (CodeStatsRange) async throws -> CodeStatsReport?
    var start: @Sendable () async throws -> CodeStatsActiveRun
    var cancel: @Sendable () async throws -> CodeStatsStatus
    var profile: @Sendable () async throws -> CodeStatsProfileLookup
    var authors: @Sendable () async throws -> [CodeStatsDiscoveredAuthor]
    var updates: @Sendable () -> AsyncStream<CodeStatsStatus>

    static var live: CodeStatsPageService {
        let client = CodeStatsAgentClient()
        return CodeStatsPageService(
            status: { try await client.status() },
            report: { try await client.report($0) },
            start: { try await client.start() },
            cancel: { try await client.cancel() },
            profile: { try await client.profile() },
            authors: { try await client.authors() },
            updates: { AgentTopicStream.values(CodeStatsStatus.self, topic: .codeStats) })
    }
}
