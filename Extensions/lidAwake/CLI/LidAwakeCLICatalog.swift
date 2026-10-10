import ArgumentParser
import EdithExtensionCommands
import Foundation

@MainActor enum LidAwakeCLICatalog {
    static func data() throws -> Data {
        var commands: [[String: Any]] = []
        func walk(_ command: ParsableCommand.Type, route: [String]) {
            let configuration = command.configuration
            if configuration.subcommands.isEmpty || configuration.defaultSubcommand != nil {
                let path = route.dropFirst().joined(separator: " ")
                let metadata: [String: Any] = [
                    "route": route, "operation": "lidAwake.cli", "summary": configuration.abstract,
                    "destructive": Set<String>(["battery", "on", "restore-on-quit", "start"])
                        .contains(path),
                    "timeout": 30,
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
        walk(LidAwakeCLICommand.self, route: ["lid-awake"])
        let help = try JSONSerialization.jsonObject(with: Data(LidAwakeCLICommand._dumpHelp().utf8))
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "owner": "lidAwake", "commands": commands, "settings": [],
                "acceptsInput": false, "parserHelp": [help],
            ], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
