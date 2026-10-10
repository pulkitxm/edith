import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum QuinjetCLIExecution {
    static func run(_ request: ExtensionCLIRequest, worker: QuinjetWorker) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        let reply = try await QuinjetCLIEnvironment.$context.withValue(makeContext(worker: worker))
        {
            try await ExtensionCLIExecution.run(QuinjetCommand.self, request: request)
        }
        try Task.checkCancellation()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return reply
    }

    static func invokeStream(
        _ operation: String, payload: Data, worker: QuinjetWorker,
        streams: ExtensionCLIStreams
    ) throws -> Data {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return try QuinjetCLIEnvironment.$context.withValue(makeContext(worker: worker)) {
            try streams.invoke(
                QuinjetCommand.self, operation: operation,
                prefix: "quinjet.cli", payload: payload)
        }
    }

    private static func makeContext(worker: QuinjetWorker) -> QuinjetCLIEnvironment.Context {
        let client = worker.client
        return .init(
            client: client,
            session: { request in
                guard await !worker.isStopped else { throw ExtensionPeerError.unavailable }
                try Task.checkCancellation()
                return try await worker.model.performSessionOperation(request)
            })
    }
}
