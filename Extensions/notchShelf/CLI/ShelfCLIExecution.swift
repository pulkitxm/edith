import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum ShelfCLIEnvironment {
    nonisolated(unsafe) static var defaults = UserDefaults(suiteName: "edith.shelf.unconfigured")!
    static var share: ([UUID]) async throws -> Void = { _ in
        throw CLIFailure.unavailable("the shelf share picker could not open")
    }
}

@MainActor enum ShelfCLIExecution {
    private static var running = false

    static func run(
        _ request: ExtensionCLIRequest, root: URL, defaults: UserDefaults,
        share: @escaping ([UUID]) async throws -> Void
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        guard !running else {
            throw ExtensionPeerError.rejected("Another shelf command is running.")
        }
        running = true
        let previousRoot = ShelfIndex.root
        let previousDefaults = ShelfCLIEnvironment.defaults
        let previousShare = ShelfCLIEnvironment.share
        ShelfIndex.root = root
        ShelfCLIEnvironment.defaults = defaults
        ShelfCLIEnvironment.share = share
        defer {
            ShelfIndex.root = previousRoot
            ShelfCLIEnvironment.defaults = previousDefaults
            ShelfCLIEnvironment.share = previousShare
            running = false
        }
        return try await ExtensionCLIExecution.run(ShelfCommand.self, arguments: request.arguments)
    }
}
