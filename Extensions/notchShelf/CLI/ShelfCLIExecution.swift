import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct ShelfCLIConfiguration: @unchecked Sendable {
    let root: URL
    let defaults: UserDefaults
    let open: @MainActor (URL) -> Bool
    let reveal: @MainActor ([URL]) -> Void
    let share: @MainActor ([UUID]) async throws -> Void
}

enum ShelfCLIEnvironment {
    @TaskLocal static var configuration: ShelfCLIConfiguration?
    static var root: URL { configuration?.root ?? ShelfIndex.root }
    static var defaults: UserDefaults? { configuration?.defaults }
    @MainActor static var open: @MainActor (URL) -> Bool {
        configuration?.open ?? { NSWorkspace.shared.open($0) }
    }
    @MainActor static var reveal: @MainActor ([URL]) -> Void {
        configuration?.reveal ?? { NSWorkspace.shared.activateFileViewerSelecting($0) }
    }
    @MainActor static func share(_ ids: [UUID]) async throws {
        guard let configuration else { throw ExtensionPeerError.unavailable }
        try await configuration.share(ids)
    }
}

@MainActor enum ShelfCLIExecution {
    static func run(
        _ request: ExtensionCLIRequest, root: URL, defaults: UserDefaults,
        open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        reveal: @escaping @MainActor ([URL]) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting($0)
        },
        share: @escaping @MainActor ([UUID]) async throws -> Void
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        let configuration = ShelfCLIConfiguration(
            root: root, defaults: defaults, open: open, reveal: reveal, share: share)
        return try await ShelfCLIEnvironment.$configuration.withValue(configuration) {
            try await ExtensionCLIExecution.run(ShelfCommand.self, request: request)
        }
    }
}
