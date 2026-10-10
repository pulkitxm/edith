import ArgumentParser
import EdithExtensionCommands
import Foundation

@MainActor enum SystemCLICatalog {
    static func data() throws -> Data {
        var commands: [[String: Any]] = []
        func walk(_ command: ParsableCommand.Type, route: [String]) {
            let configuration = command.configuration
            if configuration.subcommands.isEmpty || configuration.defaultSubcommand != nil {
                let path = route.dropFirst().joined(separator: " ")
                let metadata: [String: Any] = [
                    "route": route, "operation": "system.cli", "summary": configuration.abstract,
                    "destructive": Set<String>(["quit"]).contains(path), "timeout": 30,
                ]
                commands.append(metadata)
            }
            for child in configuration.subcommands {
                guard let name = child.configuration.commandName else { continue }
                for name in [name] + child.configuration.aliases {
                    walk(child, route: route + [name])
                }
            }
        }
        walk(AppsCommand.self, route: ["apps"])
        let help = try JSONSerialization.jsonObject(with: Data(AppsCommand._dumpHelp().utf8))
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "owner": "system", "commands": commands, "settings": [],
                "acceptsInput": false, "parserHelp": [help],
            ], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
