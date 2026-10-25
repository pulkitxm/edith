import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum MaintenanceCLIExecution {
    static func run(_ request: ExtensionCLIRequest) async throws -> ExtensionCLIReply {
        try request.validate()
        return try await ExtensionCLIExecution.run(
            MaintenanceCommand.self, request: request)
    }
}
