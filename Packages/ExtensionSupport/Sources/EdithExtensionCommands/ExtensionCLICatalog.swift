import ArgumentParser
import EdithExtensionSupport
import Foundation

public enum ExtensionCLICatalog {
    public static let destructiveNames: Set<String> = [
        "add", "apply", "cancel", "clean", "clear", "create", "delete", "disable", "edit",
        "enable", "erase", "forget", "import", "install", "insert", "kill", "move", "pause",
        "pick", "play", "purge", "quit", "record", "remove", "rename", "reset", "restore",
        "resume", "run", "save", "send", "set", "start", "stop", "trash", "uninstall",
        "update", "upgrade", "write",
    ]

    public static func data<Command: ParsableCommand>(
        _ root: Command.Type, owner: String, payload: Data, streaming: Bool,
        timeout: Double = 120, destructive: Set<String> = destructiveNames
    ) throws -> Data {
        guard payload == Data("{}".utf8),
            var help = try JSONSerialization.jsonObject(with: Data(root._dumpHelp().utf8))
                as? [String: Any],
            let command = help["command"] as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        let tree = withoutHelp(command)
        help["command"] = tree
        var commands: [[String: Any]] = []
        func append(_ node: [String: Any], prefix: [String]) throws {
            guard let name = node["commandName"] as? String, !name.isEmpty,
                name.utf8.count <= 80, prefix.count < 12
            else { throw ExtensionPeerError.invalidRequest }
            let route = prefix + [name]
            let summary = (node["abstract"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            var entry: [String: Any] = [
                "route": route, "operation": owner + ".cli", "summary": summary,
                "destructive": destructive.contains(name), "timeout": timeout,
                "readsInput": false, "jsonOutput": true,
            ]
            if streaming {
                entry["streamOperation"] = owner + ".cli"
                entry["streamDeadline"] = 21_600
            }
            commands.append(entry)
            for child in node["subcommands"] as? [[String: Any]] ?? [] {
                try append(child, prefix: route)
            }
        }
        try append(tree, prefix: [])
        guard commands.count <= 128 else { throw ExtensionPeerError.invalidRequest }
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "owner": owner, "commands": commands, "settings": [],
                "acceptsInput": false, "parserHelp": [help],
            ], options: [.sortedKeys])
    }

    static func withoutHelp(_ node: [String: Any]) -> [String: Any] {
        var node = node
        if let children = node["subcommands"] as? [[String: Any]] {
            node["subcommands"] = children.filter { $0["commandName"] as? String != "help" }
                .map(withoutHelp)
        }
        return node
    }
}
