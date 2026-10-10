import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum HomebrewCLIEnvironment {
    static var owner = HomebrewEngineCommands()
}

@MainActor enum HomebrewCLIExecution {
    private static var executing = false
    static func run(_ request: ExtensionCLIRequest, owner: HomebrewEngineCommands) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        if request.arguments.first == "cancel",
            let parsed = try? HomebrewCommand.parseAsRoot(request.arguments),
            let command = parsed as? HomebrewCancelCommand
        {
            let cancelled = owner.cancel()
            let output =
                command.json
                ? JSONSerializer.string(
                    .object([
                        "action": .string("cancel"), "commands": .array([]),
                        "window": .int(cancelled ? 1 : 0),
                    ]))
                : cancelled
                    ? "cancelled 1 window operation and 0 command"
                    : "no Homebrew operation is in progress"
            return try ExtensionCLIReply(stdout: output + "\n", stderr: "", exitCode: 0)
        }
        while executing {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        executing = true
        defer { executing = false }
        let previous = HomebrewCLIEnvironment.owner
        HomebrewCLIEnvironment.owner = owner
        defer { HomebrewCLIEnvironment.owner = previous }
        return try await ExtensionCLIExecution.run(
            HomebrewCommand.self, arguments: request.arguments)
    }
}
