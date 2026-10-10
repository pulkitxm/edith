import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum LaTeXCLIExecution {
    static func run(
        _ request: ExtensionCLIRequest, input: Data = Data(), store: LaTeXProjectStore = .init(),
        service: LaTeXService = .live
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        guard input.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        let oldStore = LaTeXCLIEnvironment.store
        let oldService = LaTeXCLIEnvironment.service
        let oldInput = LaTeXCLIEnvironment.input
        LaTeXCLIEnvironment.store = store
        LaTeXCLIEnvironment.service = service
        LaTeXCLIEnvironment.input = { input }
        defer {
            LaTeXCLIEnvironment.store = oldStore
            LaTeXCLIEnvironment.service = oldService
            LaTeXCLIEnvironment.input = oldInput
        }
        return try await ExtensionCLIExecution.run(LaTeXCommand.self, arguments: request.arguments)
    }
}

struct LaTeXCLIInput: Decodable {
    var input: Data?
}
