import EdithExtensionSupport
import EdithExtensionUI
import Foundation

struct CodeStatsPageService: Sendable {
    var status: @Sendable () async throws -> CodeStatsStatus
    var report: @Sendable (CodeStatsRange) async throws -> CodeStatsReport?
    var facts: @Sendable () async throws -> CodeStatsFactTable? = { nil }
    var start: @Sendable () async throws -> CodeStatsActiveRun
    var cancel: @Sendable () async throws -> CodeStatsStatus
    var profile: @Sendable () async throws -> CodeStatsProfileLookup
    var authors: @Sendable () async throws -> [CodeStatsDiscoveredAuthor]
    var updates: @Sendable () -> AsyncStream<CodeStatsStatus>

    static var live: CodeStatsPageService {
        let workflow = CodeStatsWorkerOperations.workflow
        return CodeStatsPageService(
            status: {
                guard let workflow else { throw ExtensionPeerError.unavailable };
                return await workflow.status()
            },
            report: { range in
                guard let workflow else { throw ExtensionPeerError.unavailable }
                return try JSONDecoder().decode(
                    CodeStatsReport?.self,
                    from: await workflow.perform(
                        operation: CodeStatsCommand.report,
                        payload: JSONEncoder().encode(CodeStatsReportQuery(range))))
            },
            facts: {
                guard let workflow else { throw ExtensionPeerError.unavailable }
                return try JSONDecoder().decode(
                    CodeStatsFactTable?.self,
                    from: await workflow.perform(operation: CodeStatsCommand.facts, payload: Data())
                )
            },
            start: {
                guard let workflow else { throw ExtensionPeerError.unavailable };
                return try await workflow.start(.manual)
            },
            cancel: {
                guard let workflow else { throw ExtensionPeerError.unavailable };
                try await workflow.cancel(); return await workflow.status()
            },
            profile: {
                guard let workflow else { throw ExtensionPeerError.unavailable };
                return await workflow.profile()
            },
            authors: {
                guard let workflow else { throw ExtensionPeerError.unavailable };
                return try await workflow.authors()
            },
            updates: {
                AsyncStream { continuation in
                    let task = Task {
                        if let workflow {
                            for await next in await workflow.updates() { continuation.yield(next) }
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            })
    }
}

enum CodeStatsWorkerOperations {
    private static let storage = CodeStatsLocked<CodeStatsWorkflow?>(nil)
    static var workflow: CodeStatsWorkflow? {
        get { storage.update { $0 } }
        set { storage.update { $0 = newValue } }
    }
}
