import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum BifrostCLIEnvironment {
    @TaskLocal static var open: @MainActor @Sendable (String) throws -> Void = { _ in
        throw ExtensionPeerError.unavailable
    }
    @TaskLocal static var reindex: @MainActor @Sendable () throws -> Void = {
        throw ExtensionPeerError.unavailable
    }
}
@MainActor enum BifrostCLIExecution {
    private static func bind<Value>(_ store: BifrostStore, operation: () async throws -> Value)
        async throws -> Value
    {
        try await BifrostCLIEnvironment.$open.withValue({ BifrostPanel.shared.show(query: $0) }) {
            try await BifrostCLIEnvironment.$reindex.withValue({ store.reindex() }) {
                try await operation()
            }
        }
    }
    static func run(_ request: ExtensionCLIRequest, store: BifrostStore) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        return try await bind(store) {
            try await ExtensionCLIExecution.run(BifrostCLICommand.self, request: request)
        }
    }
    static func stream(
        _ streams: ExtensionCLIStreams, operation: String, payload: Data, store: BifrostStore
    ) async throws -> Data {
        try await bind(store) {
            try streams.invoke(
                BifrostCLICommand.self, operation: operation, prefix: "bifrost.cli",
                payload: payload)
        }
    }
}
