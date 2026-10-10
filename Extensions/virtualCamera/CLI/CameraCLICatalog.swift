import ArgumentParser
import EdithExtensionCommands
import Foundation

@MainActor enum CameraCLICatalog {
    static func data() throws -> Data {
        var commands: [[String: Any]] = []
        func walk(_ command: ParsableCommand.Type, route: [String]) {
            let configuration = command.configuration
            if configuration.subcommands.isEmpty || configuration.defaultSubcommand != nil {
                let path = route.dropFirst().joined(separator: " ")
                var metadata: [String: Any] = [
                    "route": route, "operation": "camera.cli", "summary": configuration.abstract,
                    "destructive": ["extension install", "extension remove", "scene delete"]
                        .contains(path), "timeout": 30,
                ]
                if path != "cancel" {
                    metadata["streamOperation"] = "camera.cli.stream";
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
        walk(CameraCommand.self, route: ["camera"])
        let help = try JSONSerialization.jsonObject(with: Data(CameraCommand._dumpHelp().utf8))
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "owner": "virtualCamera", "commands": commands, "settings": [],
                "acceptsInput": false, "parserHelp": [help],
            ], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
