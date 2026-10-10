import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum HomebrewCLIEnvironment {
    static var owner = HomebrewEngineCommands()
}

@MainActor enum HomebrewCLIExecution {
    static func run(_ request: ExtensionCLIRequest, owner: HomebrewEngineCommands) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        let previous = HomebrewCLIEnvironment.owner
        HomebrewCLIEnvironment.owner = owner
        defer { HomebrewCLIEnvironment.owner = previous }
        return try await ExtensionCLIExecution.run(
            HomebrewCommand.self, arguments: request.arguments)
    }
}
