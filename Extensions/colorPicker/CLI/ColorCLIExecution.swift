import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum ColorCLIEnvironment {
    static var defaults = SharedDefaults.store
    static var pick: () -> Void = {}
    static var write: (String) -> Bool = { _ in false }
    static var changed: () -> Void = {}
}

@MainActor enum ColorCLIExecution {
    static func run(
        _ request: ExtensionCLIRequest, defaults: UserDefaults,
        pick: @escaping () -> Void, write: @escaping (String) -> Bool,
        changed: @escaping () -> Void
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        let previous = (
            ColorCLIEnvironment.defaults, ColorCLIEnvironment.pick,
            ColorCLIEnvironment.write, ColorCLIEnvironment.changed
        )
        ColorCLIEnvironment.defaults = defaults
        ColorCLIEnvironment.pick = pick
        ColorCLIEnvironment.write = write
        ColorCLIEnvironment.changed = changed
        defer {
            (
                ColorCLIEnvironment.defaults, ColorCLIEnvironment.pick,
                ColorCLIEnvironment.write, ColorCLIEnvironment.changed
            ) = previous
        }
        return try await ExtensionCLIExecution.run(ColorCommand.self, arguments: request.arguments)
    }
}
