import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI

@Suite struct CommandTreeDerivationTests {
    private func paths(of node: CommandNode, prefix: [String]) -> [[String]] {
        let here = prefix + [node.name]
        return [here] + node.children.flatMap { paths(of: $0, prefix: here) }
    }

    @Test func everySpecKeyNamesARealCommand() {
        let known = Set(paths(of: CommandTree.root, prefix: []).map { $0.joined(separator: " ") })
            .union(["help"])
        let stale = Set(CommandTree.specs.keys).subtracting(known)
        #expect(
            stale.isEmpty, "the completion spec table names commands that do not exist: \(stale)")
    }

    @Test func structureComesFromTheArgumentParser() {
        #expect(CommandTree.root.name == EdRoot.configuration.commandName)
        #expect(CommandTree.root.summary == EdRoot.configuration.abstract)
        let visible = EdRoot.configuration.subcommands
            .filter { $0.configuration.shouldDisplay }
            .compactMap { $0.configuration.commandName }
        #expect(CommandTree.root.children.map(\.name) == visible)
    }

    @Test func everySummaryMatchesItsCommandAbstract() {
        func check(_ command: ParsableCommand.Type, node: CommandNode) {
            #expect(node.summary == command.configuration.abstract, "\(node.name) summary drifted")
            #expect(node.aliases == command.configuration.aliases, "\(node.name) aliases drifted")
            let children = command.configuration.subcommands
                .filter { $0.configuration.shouldDisplay }
            #expect(children.count == node.children.count)
            for (child, childNode) in zip(children, node.children) {
                check(child, node: childNode)
            }
        }
        check(EdRoot.self, node: CommandTree.root)
    }

    @Test func hiddenCommandsStayOutOfCompletions() {
        #expect(CommandTree.root.child("__complete") == nil)
        #expect(CommandTree.node(at: ["herdr", "bridge"]) == nil)
        #expect(!CommandTree.topLevelNames.contains("__complete"))
    }
}
