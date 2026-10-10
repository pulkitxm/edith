import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum ShelfCLIEnvironment {
    nonisolated(unsafe) static var defaults: UserDefaults?
    static var open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    static var reveal: @MainActor ([URL]) -> Void = {
        NSWorkspace.shared.activateFileViewerSelecting($0)
    }
    static var share: ([UUID]) async throws -> Void = { _ in
        throw CLIFailure.unavailable("the shelf share picker could not open")
    }
}

@MainActor enum ShelfCLIExecution {
    private static var running = false

    static func run(
        _ request: ExtensionCLIRequest, root: URL, defaults: UserDefaults,
        open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        reveal: @escaping @MainActor ([URL]) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting($0)
        },
        share: @escaping ([UUID]) async throws -> Void
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        guard !running else {
            throw ExtensionPeerError.rejected("Another shelf command is running.")
        }
        running = true
        let previousRoot = ShelfIndex.root
        let previousDefaults = ShelfCLIEnvironment.defaults
        let previousOpen = ShelfCLIEnvironment.open
        let previousReveal = ShelfCLIEnvironment.reveal
        let previousShare = ShelfCLIEnvironment.share
        ShelfIndex.root = root
        ShelfCLIEnvironment.defaults = defaults
        ShelfCLIEnvironment.open = open
        ShelfCLIEnvironment.reveal = reveal
        ShelfCLIEnvironment.share = share
        defer {
            ShelfIndex.root = previousRoot
            ShelfCLIEnvironment.defaults = previousDefaults
            ShelfCLIEnvironment.open = previousOpen
            ShelfCLIEnvironment.reveal = previousReveal
            ShelfCLIEnvironment.share = previousShare
            running = false
        }
        return try await ExtensionCLIExecution.run(ShelfCommand.self, arguments: request.arguments)
    }
}
