import ArgumentParser
import EdithExtensionSupport
import Foundation

enum HerdrCLICatalog {
    static func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "owner": "herdr", "commands": commands(HerdrCLICommand.self, route: []),
            "settings": [], "acceptsInput": false,
        ])
    }

    private static func commands(_ command: ParsableCommand.Type, route: [String]) -> [[String:
        Any]]
    {
        let configuration = command.configuration
        guard let name = configuration.commandName else { return [] }
        let path = route + [name]
        if !configuration.subcommands.isEmpty {
            return configuration.subcommands.flatMap { commands($0, route: path) }
        }
        let destructive = [
            "close", "rm", "delete", "clear", "close-tab", "close-others",
            "close-right", "close-all",
        ].contains(name)
        return [
            [
                "route": path, "operation": "herdr.cli", "summary": configuration.abstract,
                "destructive": destructive, "timeout": 30,
                "streamOperation": "herdr.cli", "streamDeadline": 1800,
                "readsInput": false, "jsonOutput": name != "launch",
            ]
        ]
    }
}
