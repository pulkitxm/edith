import ArgumentParser
import ArgumentParserToolInfo
import EdithExtensionSupport
import Foundation

struct CalendarCLICatalog: Codable {
    struct Command: Codable, Equatable {
        let route: [String]
        let operation: String
        let summary: String
        let destructive: Bool
        let timeout: Int
        let readsInput: Bool
        let jsonOutput: Bool
    }

    let version: Int
    let owner: String
    let commands: [Command]
    let settings: [String]
    let acceptsInput: Bool
    let parserHelp: [ToolInfoV0]

    static func encoded(_ payload: Data) throws -> Data {
        guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
        let help = try JSONDecoder().decode(
            ToolInfoV0.self, from: Data(CalendarCommand._dumpHelp().utf8))
        guard help.serializationVersion == 0, help.command.commandName == "calendar" else {
            throw ExtensionPeerError.invalidRequest
        }
        var commands: [Command] = []
        func append(_ command: CommandInfoV0, prefix: [String]) throws {
            guard !command.commandName.isEmpty, let summary = command.abstract,
                !summary.isEmpty, prefix.count < 12, commands.count < 128
            else { throw ExtensionPeerError.invalidRequest }
            let route = prefix + [command.commandName]
            commands.append(
                Command(
                    route: route, operation: "calendar.cli", summary: summary,
                    destructive: false, timeout: 30, readsInput: false,
                    jsonOutput: command.commandName != "help"))
            for child in command.subcommands ?? [] { try append(child, prefix: route) }
        }
        try append(help.command, prefix: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            CalendarCLICatalog(
                version: 1, owner: "calendar", commands: commands, settings: [],
                acceptsInput: false, parserHelp: [help]))
    }
}
