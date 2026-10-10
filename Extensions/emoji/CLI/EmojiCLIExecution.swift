import ArgumentParser
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
    static func catalog(_ payload: Data) throws -> Data {
        guard payload == Data("{}".utf8),
            let help = try JSONSerialization.jsonObject(with: Data(EmojiCommand._dumpHelp().utf8))
                as? [String: Any],
            let root = help["command"] as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        var commands: [[String: Any]] = []
        func append(_ command: [String: Any], prefix: [String]) throws {
            guard let name = command["commandName"] as? String,
                !name.isEmpty, name.utf8.count <= 80, prefix.count < 12,
                let summary = command["abstract"] as? String, !summary.isEmpty
            else { throw ExtensionPeerError.invalidRequest }
            let route = prefix + [name]
            guard route.first == "emoji" else { throw ExtensionPeerError.invalidRequest }
            if !route.isEmpty {
                let entry: [String: Any] = [
                    "route": route, "operation": "emoji.cli", "summary": summary,
                    "destructive": Set<String>(["clear", "forget", "insert", "pick", "tone"])
                        .contains(name), "timeout": 30,
                    "readsInput": false, "jsonOutput": false,
                ]
                commands.append(entry)
            }
            for child in command["subcommands"] as? [[String: Any]] ?? [] {
                try append(child, prefix: route)
            }
        }
        try append(root, prefix: [])
        guard !commands.isEmpty, commands.count <= 128 else {
            throw ExtensionPeerError.invalidRequest
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "owner": "emoji", "commands": commands,
                "settings": [], "acceptsInput": false, "parserHelp": [help],
            ], options: [.sortedKeys])
    }

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
        return try await ExtensionCLIExecution.run(EmojiCommand.self, request: request)
    }
}
