import ArgumentParser
import EdithExtensionCommands
import Foundation
import Testing

struct ExtensionCLICatalogTests {
    struct Root: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sample", abstract: "Sample commands.",
            subcommands: [List.self, Remove.self])
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: "List items.")
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove", abstract: "Remove an item.")
    }

    private func catalog(streaming: Bool) throws -> [String: Any] {
        let data = try ExtensionCLICatalog.data(
            Root.self, owner: "sample", payload: Data("{}".utf8), streaming: streaming)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func declaresEveryRouteWithoutTheBuiltInHelpCommand() throws {
        let value = try catalog(streaming: false)
        #expect(value["owner"] as? String == "sample")
        let commands = try #require(value["commands"] as? [[String: Any]])
        let routes = commands.compactMap { $0["route"] as? [String] }
        #expect(routes == [["sample"], ["sample", "ls"], ["sample", "remove"]])
        #expect(commands.allSatisfy { $0["operation"] as? String == "sample.cli" })
        #expect(commands.allSatisfy { $0["streamOperation"] == nil })
        let destructive = commands.filter { $0["destructive"] as? Bool == true }
            .compactMap { ($0["route"] as? [String])?.last }
        #expect(destructive == ["remove"])
        let help = try #require((value["parserHelp"] as? [[String: Any]])?.first)
        let root = try #require(help["command"] as? [String: Any])
        let names = (root["subcommands"] as? [[String: Any]] ?? []).compactMap {
            $0["commandName"] as? String
        }
        #expect(!names.contains("help"))
    }

    @Test func streamingCommandsUseTheOwnerStreamOperation() throws {
        let commands = try #require(try catalog(streaming: true)["commands"] as? [[String: Any]])
        #expect(commands.allSatisfy { $0["streamOperation"] as? String == "sample.cli" })
    }

    @Test func rejectsANonEmptyPayload() {
        #expect(throws: (any Error).self) {
            try ExtensionCLICatalog.data(
                Root.self, owner: "sample", payload: Data("{\"x\":1}".utf8), streaming: false)
        }
    }
}
