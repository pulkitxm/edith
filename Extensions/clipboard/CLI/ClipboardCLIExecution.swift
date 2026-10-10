import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

enum ClipboardCLIEnvironment {
    nonisolated(unsafe) static var client = ClipboardClient(send: { _, _ in
        throw CLIFailure.unavailable("the Clipboard extension is off")
    })
    nonisolated(unsafe) static var defaults = SharedDefaults.store
    nonisolated(unsafe) static var copy: @MainActor (ClipboardCopyPayload) throws -> Void = {
        ClipboardRepository.copyToPasteboard($0, pasteboard: .general)
    }
}

@MainActor enum ClipboardCLIExecution {
    static func run(
        _ request: ExtensionCLIRequest, client: ClipboardClient,
        defaults: UserDefaults = SharedDefaults.store,
        copy: @escaping @MainActor (ClipboardCopyPayload) throws -> Void = {
            ClipboardRepository.copyToPasteboard($0, pasteboard: .general)
        }
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        let previousClient = ClipboardCLIEnvironment.client
        let previousDefaults = ClipboardCLIEnvironment.defaults
        let previousCopy = ClipboardCLIEnvironment.copy
        ClipboardCLIEnvironment.client = client
        ClipboardCLIEnvironment.defaults = defaults
        ClipboardCLIEnvironment.copy = copy
        defer {
            ClipboardCLIEnvironment.client = previousClient
            ClipboardCLIEnvironment.defaults = previousDefaults
            ClipboardCLIEnvironment.copy = previousCopy
        }
        return try await ExtensionCLIExecution.run(
            ClipboardCommand.self, arguments: request.arguments)
    }
}
