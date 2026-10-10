import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct CodeStatsCLIClient: Sendable {
    private var workflow: CodeStatsWorkflow {
        get throws {
            guard let workflow = CodeStatsWorkerOperations.workflow else {
                throw ExtensionPeerError.unavailable
            }
            return workflow
        }
    }
    func status() async throws -> CodeStatsStatus { try await workflow.status() }
    func report(_ range: CodeStatsRange, filter: CodeStatsFilter = .default) async throws
        -> CodeStatsReport?
    {
        try JSONDecoder().decode(
            CodeStatsReport?.self,
            from: await workflow.perform(
                operation: CodeStatsCommand.report,
                payload: JSONEncoder().encode(CodeStatsReportQuery(range, filter: filter))))
    }
    func authors() async throws -> [CodeStatsDiscoveredAuthor] { try await workflow.authors() }
    func start() async throws -> CodeStatsActiveRun { try await workflow.start(.manual) }
    func cancel() async throws -> CodeStatsStatus {
        let value = try workflow; try await value.cancel(); return await value.status()
    }
    func audit() async throws -> CodeStatsAudit? {
        try JSONDecoder().decode(
            CodeStatsAudit?.self,
            from: await workflow.perform(operation: CodeStatsCommand.audit, payload: Data()))
    }
}
@MainActor enum CodeStatsCLIExecution {
    static func run(_ request: ExtensionCLIRequest) async throws -> ExtensionCLIReply {
        try request.validate()
        guard CodeStatsWorkerOperations.workflow != nil else {
            throw ExtensionPeerError.unavailable
        }
        return try await ExtensionCLIExecution.run(
            CodeStatsCLICommand.self, arguments: request.arguments)
    }
}
