import ArgumentParser
import EdithExtensionCommands
import Foundation

@MainActor enum JevCLICatalog {
    static func data() throws -> Data {
        var commands: [[String: Any]] = []
        func walk(_ command: ParsableCommand.Type, route: [String]) {
            let configuration = command.configuration
            if configuration.subcommands.isEmpty || configuration.defaultSubcommand != nil {
                let path = route.dropFirst().joined(separator: " ")
                var metadata: [String: Any] = [
                    "route": route, "operation": "jev.cli", "summary": configuration.abstract,
                    "destructive": Set<String>(["key clear"]).contains(path), "timeout": 30,
                    "readsInput": ["key set", "ask"].contains(path),
                ]
                if path != "cancel" {
                    metadata["streamOperation"] = "jev.cli.stream";
                    metadata["streamDeadline"] = 1800
                }
                commands.append(metadata)
            }
            for child in configuration.subcommands {
                guard let name = child.configuration.commandName else { continue }
                for name in [name] + child.configuration.aliases {
                    walk(child, route: route + [name])
                }
            }
        }
        walk(JevCommand.self, route: ["jev"])
        let help = try JSONSerialization.jsonObject(with: Data(JevCommand._dumpHelp().utf8))
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "owner": "jev", "commands": commands, "settings": [],
                "acceptsInput": true, "parserHelp": [help],
            ], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
