import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum HerdrCLICatalog {
    private static var cached: Data?

    static func data() throws -> Data {
        if let cached { return cached }
        let data = try build()
        cached = data
        return data
    }

    private static func build() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "owner": "herdr", "commands": commands(HerdrCLICommand.self, route: []),
            "settings": [], "acceptsInput": true,
            "parserHelp": [try ExtensionCLICatalog.parserHelp(HerdrCLICommand.self)],
            "coreOwner": try HerdrAgentCLIExecution.catalog(),
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
                "readsInput": name == "attach", "jsonOutput": name != "launch",
            ]
        ]
    }
}
