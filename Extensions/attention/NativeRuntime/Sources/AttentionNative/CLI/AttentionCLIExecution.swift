@_implementationOnly import EdithExtensionCommands
@_implementationOnly import EdithExtensionSupport
import Foundation

@MainActor enum AttentionCLIExecution {
    static func run(
        _ request: ExtensionCLIRequest, repository: AttentionRepository,
        service: AttentionBackgroundService? = nil
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        let previousRepository = AttentionCLIEnvironment.repository
        let previousService = AttentionCLIEnvironment.service
        AttentionCLIEnvironment.repository = repository
        AttentionCLIEnvironment.service = service
        defer {
            AttentionCLIEnvironment.repository = previousRepository
            AttentionCLIEnvironment.service = previousService
        }
        return try await ExtensionCLIExecution.run(
            AttentionCommand.self, request: request)
    }

    static func categorize() async throws -> AttentionCategorizeReport {
        guard let service = AttentionCLIEnvironment.service else {
            throw CLIFailure.unavailable("Attention engine is unavailable")
        }
        return try await service.categorize()
    }
    static func backup() async throws {
        guard let service = AttentionCLIEnvironment.service else {
            throw CLIFailure.unavailable("Attention engine is unavailable")
        }
        try await service.backup()
    }
    static func restore() async throws {
        guard let service = AttentionCLIEnvironment.service else {
            throw CLIFailure.unavailable("Attention engine is unavailable")
        }
        try await service.restore()
    }
}
