import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

struct CommandWalk {
    let path: [String]
    let type: ParsableCommand.Type

    var label: String { path.joined(separator: " ") }
    var invocation: [String] { Array(path.dropFirst()) }
}

enum CommandCrawler {
    static func name(of command: ParsableCommand.Type) -> String {
        command.configuration.commandName ?? String(describing: command).lowercased()
    }

    static func every(from root: ParsableCommand.Type = EdRoot.self) -> [CommandWalk] {
        var found: [CommandWalk] = []
        var queue = [CommandWalk(path: ["ed"], type: root)]
        while let next = queue.popLast() {
            found.append(next)
            for child in next.type.configuration.subcommands {
                queue.append(CommandWalk(path: next.path + [name(of: child)], type: child))
            }
        }
        return found.sorted { $0.label < $1.label }
    }

    static func help(_ command: ParsableCommand.Type) -> String {
        command.helpMessage(columns: 400)
    }

    static func usageLine(_ command: ParsableCommand.Type) -> String {
        let text = help(command)
        guard let range = text.range(of: "USAGE:") else { return "" }
        return String(text[range.upperBound...])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    static func optionalPositionals(_ command: ParsableCommand.Type) -> [String] {
        matches(in: usageLine(command), pattern: "\\[<[^>]+>\\]")
    }

    static func requiredPositionals(_ command: ParsableCommand.Type) -> [String] {
        let line = usageLine(command)
        guard let brackets = try? NSRegularExpression(pattern: "\\[[^\\]]*\\]") else {
            return []
        }
        let bare = brackets.stringByReplacingMatches(
            in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        return matches(in: bare, pattern: "<[^>]+>")
    }

    static func optionNames(of command: ParsableCommand.Type) -> Set<String> {
        Set(matches(in: help(command), pattern: "--[a-zA-Z][a-zA-Z0-9-]*"))
    }

    static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}

@Suite struct CLICommandShapeTests {
    static let commands = CommandCrawler.every()

    @Test func noCommandHidesItsSubcommandsBehindAnOptionalPositional() {
        var broken: [String] = []
        for walk in Self.commands where !walk.type.configuration.subcommands.isEmpty {
            let optional = CommandCrawler.optionalPositionals(walk.type)
            guard !optional.isEmpty else { continue }
            broken.append("\(walk.label) \(optional.joined(separator: " "))")
        }
        #expect(
            broken.isEmpty,
            "an optional positional swallows the subcommand name in: \(broken)")
    }

    @Test func everySubcommandIsReachableByName() throws {
        var unreachable: [String] = []
        for walk in Self.commands {
            for child in walk.type.configuration.subcommands {
                let name = CommandCrawler.name(of: child)
                let arguments = walk.invocation + [name]
                guard let parsed = try? EdRoot.parseAsRoot(arguments) else { continue }
                let landed = CommandCrawler.name(of: type(of: parsed))
                var allowed: Set<String> = [name]
                if let fallback = child.configuration.defaultSubcommand {
                    allowed.insert(CommandCrawler.name(of: fallback))
                }
                guard allowed.contains(landed) else {
                    unreachable.append("ed \(arguments.joined(separator: " ")) -> \(landed)")
                    continue
                }
            }
        }
        #expect(
            unreachable.isEmpty, "these subcommand names never reach their command: \(unreachable)")
    }

    @Test func everyCommandNameIsUniqueAmongItsSiblings() {
        for walk in Self.commands {
            var seen: Set<String> = []
            for child in walk.type.configuration.subcommands {
                let names =
                    [CommandCrawler.name(of: child)] + child.configuration.aliases
                for name in names {
                    #expect(
                        seen.insert(name).inserted,
                        "\(walk.label) has two children answering to \(name)")
                }
            }
        }
    }

    @Test func everyCommandHasAnAbstract() {
        for walk in Self.commands {
            #expect(
                !walk.type.configuration.abstract.isEmpty,
                "\(walk.label) has no abstract, so --help says nothing")
        }
    }

    @Test func everyGroupWithSubcommandsNamesADefaultOrHasNoWorkOfItsOwn() {
        for walk in Self.commands where !walk.type.configuration.subcommands.isEmpty {
            guard walk.path != ["ed"] else { continue }
            #expect(
                walk.type.configuration.defaultSubcommand != nil,
                "\(walk.label) has subcommands but no default, so bare `\(walk.label)` errors")
        }
    }

    @Test func everyDefaultSubcommandIsAlsoListedAsASubcommand() {
        for walk in Self.commands {
            guard let fallback = walk.type.configuration.defaultSubcommand else { continue }
            #expect(
                walk.type.configuration.subcommands.contains(where: { $0 == fallback }),
                "\(walk.label) defaults to a command it does not list")
        }
    }

    @Test func aBareGroupNameResolvesToItsDefault() throws {
        for walk in Self.commands {
            guard let fallback = walk.type.configuration.defaultSubcommand,
                CommandCrawler.requiredPositionals(fallback).isEmpty
            else { continue }
            let parsed = try EdRoot.parseAsRoot(walk.invocation)
            #expect(
                CommandCrawler.name(of: type(of: parsed))
                    == CommandCrawler.name(of: fallback),
                "bare `\(walk.label)` did not fall through to its default")
        }
    }

    @Test func everyAliasReachesTheSameCommandAsItsRealName() throws {
        for walk in Self.commands where walk.path.count > 1 {
            guard CommandCrawler.requiredPositionals(walk.type).isEmpty else { continue }
            var expected = CommandCrawler.name(of: walk.type)
            if let fallback = walk.type.configuration.defaultSubcommand {
                expected = CommandCrawler.name(of: fallback)
            }
            for alias in walk.type.configuration.aliases {
                let arguments = Array(walk.invocation.dropLast()) + [alias]
                let parsed = try EdRoot.parseAsRoot(arguments)
                #expect(
                    CommandCrawler.name(of: type(of: parsed)) == expected,
                    "alias \(alias) of \(walk.label) went somewhere else")
            }
        }
    }

    @Test func everyReadCommandOffersJSON() {
        let exempt: Set<String> = [
            "ed", "ed guide", "ed schema", "ed completions", "ed completions zsh",
            "ed completions bash", "ed completions fish", "ed config export",
            "ed machines exec", "ed machines docker logs", "ed machines docker inspect",
            "ed machines files", "ed machines docker", "ed config", "ed extensions",
            "ed permissions", "ed usage", "ed system", "ed music", "ed calendar",
            "ed machines", "ed __complete", "ed app", "ed clipboard", "ed color",
            "ed shelf", "ed cleaner", "ed machines docker compose",
            "ed machines docker compose logs", "ed machines forwards",
            "ed machines snippets", "ed machines power",
            "ed apps",
            "ed tools", "ed download", "ed machines workspace", "ed usage machines",
            "ed companion", "ed companion reason", "ed companion core",
            "ed companion inquire", "ed companion eval", "ed companion machines",
            "ed companion hypotheses", "ed companion discrepancies", "ed companion standup",
            "ed companion connectors", "ed companion db", "ed companion stack",
            "ed lid-awake",
        ]
        for walk in Self.commands where !exempt.contains(walk.label) {
            #expect(
                CommandCrawler.optionNames(of: walk.type).contains("--json"),
                "\(walk.label) has no --json, so an agent cannot parse it")
        }
    }

    @Test func theHiddenCompletionCommandStaysHidden() {
        let complete = Self.commands.first { $0.label == "ed __complete" }
        #expect(complete?.type.configuration.shouldDisplay == false)
    }

    @Test func theRootCarriesAVersion() {
        #expect(EdRoot.configuration.version == edithCLIVersion)
        #expect(!edithCLIVersion.isEmpty)
    }
}

@Suite struct CLICompletionTreeParityTests {
    @Test func everyTreeNodeExistsInTheParser() {
        var missing: [String] = []
        walk(node: CommandTree.root, command: EdRoot.self, path: [], missing: &missing)
        #expect(missing.isEmpty, "the tree names commands the parser does not have: \(missing)")
    }

    private func walk(
        node: CommandNode, command: ParsableCommand.Type, path: [String], missing: inout [String]
    ) {
        for child in node.children {
            guard let match = resolve(child.name, in: command) else {
                missing.append((path + [child.name]).joined(separator: " "))
                continue
            }
            for alias in child.aliases where resolve(alias, in: command) == nil {
                missing.append((path + [alias]).joined(separator: " "))
            }
            walk(node: child, command: match, path: path + [child.name], missing: &missing)
        }
    }

    private func resolve(_ name: String, in command: ParsableCommand.Type)
        -> ParsableCommand.Type?
    {
        command.configuration.subcommands.first {
            $0.configuration.commandName == name || $0.configuration.aliases.contains(name)
        }
    }

    @Test func everyParserCommandExistsInTheTree() {
        var missing: [String] = []
        walkParser(command: EdRoot.self, node: CommandTree.root, path: [], missing: &missing)
        #expect(
            missing.isEmpty, "the parser has commands completion never offers: \(missing)")
    }

    private func walkParser(
        command: ParsableCommand.Type, node: CommandNode, path: [String], missing: inout [String]
    ) {
        for child in command.configuration.subcommands {
            let name = CommandCrawler.name(of: child)
            guard child.configuration.shouldDisplay else { continue }
            guard let match = node.child(name) else {
                missing.append((path + [name]).joined(separator: " "))
                continue
            }
            for alias in child.configuration.aliases where !match.names.contains(alias) {
                missing.append((path + [alias]).joined(separator: " "))
            }
            walkParser(command: child, node: match, path: path + [name], missing: &missing)
        }
    }

    @Test func everyOptionTheTreeAdvertisesReallyExists() {
        var wrong: [String] = []
        check(node: CommandTree.root, command: EdRoot.self, path: ["ed"], wrong: &wrong)
        #expect(wrong.isEmpty, "completion offers flags the parser rejects: \(wrong)")
    }

    private func check(
        node: CommandNode, command: ParsableCommand.Type, path: [String], wrong: inout [String]
    ) {
        let real = CommandCrawler.optionNames(of: command).union(["--help"])
        for option in node.options where !real.contains(option) {
            wrong.append((path + [option]).joined(separator: " "))
        }
        for child in node.children {
            guard
                let match = command.configuration.subcommands.first(where: {
                    CommandCrawler.name(of: $0) == child.name
                })
            else { continue }
            check(node: child, command: match, path: path + [child.name], wrong: &wrong)
        }
    }

    @Test func reservedWordsCoverEveryTopLevelNameAndAlias() {
        for child in EdRoot.configuration.subcommands {
            let names =
                [CommandCrawler.name(of: child)] + child.configuration.aliases
            for name in names {
                #expect(
                    ArgumentRewriting.reserved.contains(name),
                    "a machine called \(name) would shadow the \(name) command")
            }
        }
    }

    @Test func everyTreeNodeHasASummary() {
        var empty: [String] = []
        collect(CommandTree.root, path: [], into: &empty)
        #expect(empty.isEmpty, "completion would show a blank description for: \(empty)")
    }

    private func collect(_ node: CommandNode, path: [String], into empty: inout [String]) {
        if node.summary.isEmpty { empty.append((path + [node.name]).joined(separator: " ")) }
        for child in node.children { collect(child, path: path + [node.name], into: &empty) }
    }
}
