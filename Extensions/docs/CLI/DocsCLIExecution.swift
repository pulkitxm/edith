import EdithDocsWorker
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum DocsCLIEnvironment {
    static var library: DocsLibrary?
}

@MainActor enum DocsCLIExecution {
    static func run(_ request: ExtensionCLIRequest, browser: DocsBrowser) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        await browser.load()
        try Task.checkCancellation()
        let previous = DocsCLIEnvironment.library
        DocsCLIEnvironment.library = browser.library
        defer { DocsCLIEnvironment.library = previous }
        return try await ExtensionCLIExecution.run(
            DocsCommandGroup.self, arguments: request.arguments)
    }
}
