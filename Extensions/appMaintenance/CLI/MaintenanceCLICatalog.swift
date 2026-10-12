import ArgumentParser
import EdithExtensionCommands
import Foundation

@MainActor enum MaintenanceCLICatalog {
    static func data() throws -> Data {
        var commands: [[String: Any]] = []
        func walk(_ command: ParsableCommand.Type, route: [String]) {
            let configuration = command.configuration
            if configuration.subcommands.isEmpty || configuration.defaultSubcommand != nil {
                let path = route.dropFirst().joined(separator: " ")
                var metadata: [String: Any] = [
                    "route": route, "operation": "maintenance.cli",
                    "summary": configuration.abstract,
                    "destructive": Set<String>(["install", "remove", "reset", "update"]).contains(
                        path),
                    "timeout": 30,
                ]
                if path != "cancel" {
                    metadata["streamOperation"] = "maintenance.cli.stream";
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
        walk(MaintenanceCommand.self, route: ["maintenance"])
        let help = try JSONSerialization.jsonObject(with: Data(MaintenanceCommand._dumpHelp().utf8))
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "owner": "appMaintenance", "commands": commands, "settings": [],
                "acceptsInput": false, "parserHelp": [help],
            ], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
