import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum EmojiCLIEnvironment {
    static var defaults = SharedDefaults.store
    static var catalog = EmojiCatalog.shared
    static var pick: () -> Void = {}
    static var insert: (String) async throws -> Bool = { _ in
        throw CLIFailure.unavailable("the Emoji Picker extension is off")
    }
    static var changed: () -> Void = {}
}

@MainActor enum EmojiCLIExecution {
    static func run(
        _ request: ExtensionCLIRequest, defaults: UserDefaults, catalog: EmojiCatalog,
        pick: @escaping () -> Void, insert: @escaping (String) async throws -> Bool,
        changed: @escaping () -> Void
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        let previous = (
            EmojiCLIEnvironment.defaults, EmojiCLIEnvironment.catalog,
            EmojiCLIEnvironment.pick, EmojiCLIEnvironment.insert, EmojiCLIEnvironment.changed
        )
        EmojiCLIEnvironment.defaults = defaults
        EmojiCLIEnvironment.catalog = catalog
        EmojiCLIEnvironment.pick = pick
        EmojiCLIEnvironment.insert = insert
        EmojiCLIEnvironment.changed = changed
        defer {
            (
                EmojiCLIEnvironment.defaults, EmojiCLIEnvironment.catalog,
                EmojiCLIEnvironment.pick, EmojiCLIEnvironment.insert, EmojiCLIEnvironment.changed
            ) = previous
        }
        return try await ExtensionCLIExecution.run(EmojiCommand.self, arguments: request.arguments)
    }
}
