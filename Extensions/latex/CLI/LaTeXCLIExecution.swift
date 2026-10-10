import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum LaTeXCLIExecution {
    static func run(
        _ request: ExtensionCLIRequest, store: LaTeXProjectStore = .init(),
        service: LaTeXService = .live
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        return try await LaTeXCLIEnvironment.$store.withValue(store) {
            try await LaTeXCLIEnvironment.$service.withValue(service) {
                try await ExtensionCLIExecution.run(LaTeXCommand.self, request: request)
            }
        }
    }
    static func stream(
        _ streams: ExtensionCLIStreams, operation: String, payload: Data, store: LaTeXProjectStore
    ) throws -> Data {
        try LaTeXCLIEnvironment.$store.withValue(store) {
            try streams.invoke(
                LaTeXCommand.self, operation: operation, prefix: "latex.cli", payload: payload)
        }
    }
}
