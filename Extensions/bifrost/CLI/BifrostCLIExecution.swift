import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum BifrostCLIEnvironment {
    static var open: (String) throws -> Void = { _ in throw ExtensionPeerError.unavailable }
    static var reindex: () throws -> Void = { throw ExtensionPeerError.unavailable }
}
@MainActor enum BifrostCLIExecution {
    static func run(_ request: ExtensionCLIRequest, store: BifrostStore) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        let oldOpen = BifrostCLIEnvironment.open
        let oldReindex = BifrostCLIEnvironment.reindex
        BifrostCLIEnvironment.open = { BifrostPanel.shared.show(query: $0) }
        BifrostCLIEnvironment.reindex = { store.reindex() }
        defer { BifrostCLIEnvironment.open = oldOpen; BifrostCLIEnvironment.reindex = oldReindex }
        return try await ExtensionCLIExecution.run(
            BifrostCLICommand.self, arguments: request.arguments)
    }
}
