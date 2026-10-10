import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum QuinjetCLIExecution {
    static func run(_ request: ExtensionCLIRequest, worker: QuinjetWorker) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        let previousClient = QuinjetCLIEnvironment.client
        let previousSession = QuinjetCLIEnvironment.session
        let client = worker.client
        QuinjetCLIEnvironment.client = { client }
        QuinjetCLIEnvironment.session = { request in
            guard await !worker.isStopped else { throw ExtensionPeerError.unavailable }
            try Task.checkCancellation()
            return try await worker.model.performSessionOperation(request)
        }
        defer {
            QuinjetCLIEnvironment.client = previousClient
            QuinjetCLIEnvironment.session = previousSession
        }
        let reply = try await ExtensionCLIExecution.run(
            QuinjetCommand.self, arguments: request.arguments)
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return reply
    }
}
