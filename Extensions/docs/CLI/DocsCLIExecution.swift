import EdithDocsWorker
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum DocsCLIEnvironment {
    @TaskLocal static var library: DocsLibrary?
}

@MainActor enum DocsCLIExecution {
    static func run(_ request: ExtensionCLIRequest, browser: DocsBrowser) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        await browser.load()
        try Task.checkCancellation()
        return try await DocsCLIEnvironment.$library.withValue(browser.library) {
            try await ExtensionCLIExecution.run(DocsCommandGroup.self, request: request)
        }
    }
    static func stream(
        _ streams: ExtensionCLIStreams, operation: String, payload: Data, browser: DocsBrowser
    ) async throws -> Data {
        await browser.load()
        try Task.checkCancellation()
        return try DocsCLIEnvironment.$library.withValue(browser.library) {
            try streams.invoke(
                DocsCommandGroup.self, operation: operation, prefix: "docs.cli", payload: payload)
        }
    }
}
