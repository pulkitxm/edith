import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum UsageCLIProvider {
    private struct ParserDocument: Decodable { let command: CommandInfo }
    private struct CommandInfo: Decodable {
        let commandName: String
        let aliases: [String]?
        let `abstract`: String?
        let defaultSubcommand: String?
        let subcommands: [CommandInfo]?
        let arguments: [ArgumentInfo]?

        var names: [String] { [commandName] + (aliases ?? []) }
        var children: [CommandInfo] { subcommands ?? [] }
        var defaultCommand: CommandInfo? {
            children.first { $0.commandName == defaultSubcommand }
        }
        var options: [ArgumentInfo] {
            (arguments ?? []).filter { $0.kind != "positional" && $0.shouldDisplay != false }
        }
        var effectiveOptions: [ArgumentInfo] { options + (defaultCommand?.options ?? []) }
    }
    private struct ArgumentInfo: Decodable {
        struct Name: Decodable {
            let name: String
            let kind: String
            var option: String { (kind == "long" ? "--" : "-") + name }
        }
        let kind: String
        let shouldDisplay: Bool?
        let names: [Name]?
        var options: [String] { (names ?? []).map(\.option) }
    }
    private struct CompletionRequest: Decodable {
        let words: [String]
        let index: Int
    }

    static func catalog() throws -> Data {
        let help = Data(UsageCommand._dumpHelp().utf8)
        let document = try JSONDecoder().decode(ParserDocument.self, from: help)
        let commands = routes(document.command, parent: [])
        let settings = try UsageConfigCatalog.settings.map { definition -> [String: Any] in
            var result: [String: Any] = [
                "key": definition.key, "type": definition.type.rawValue,
                "group": definition.group, "summary": definition.summary,
                "scope": "shared", "allowed": definition.allowed,
                "fallback": try JSONSerialization.jsonObject(
                    with: Data(JSONSerializer.string(definition.fallback).utf8),
                    options: .fragmentsAllowed), "readOnly": definition.readOnly,
            ]
            if let range = definition.integerRange {
                result["minimum"] = range.lowerBound; result["maximum"] = range.upperBound
            }
            return result
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "owner": "usage", "commands": commands,
                "settings": settings, "acceptsInput": true,
                "completionOperation": "usage.cli.complete",
                "parserHelp": [try JSONSerialization.jsonObject(with: help)],
            ], options: [.sortedKeys])
    }

    private static func routes(_ command: CommandInfo, parent: [String]) -> [[String: Any]] {
        let canonical = parent + [command.commandName]
        let name = canonical.dropFirst().joined(separator: " ")
        let writes = Set([
            "refresh", "export", "attribution reset", "machines collect", "machines enable",
            "machines disable", "machines forget", "projects open", "projects copy-link",
            "projects copy-chat", "statusline install", "statusline remove", "statusline record",
        ])
        var result: [[String: Any]] = command.names.map { alias in
            [
                "route": parent + [alias], "operation": "usage.cli",
                "summary": command.abstract ?? "Agent usage.",
                "destructive": writes.contains(name), "timeout": 30,
                "streamOperation": "usage.cli", "streamDeadline": 21_600,
                "readsInput": name == "statusline record",
                "jsonOutput": name != "statusline record",
            ]
        }
        for child in command.children { result += routes(child, parent: canonical) }
        return result
    }

    static func complete(_ payload: Data) throws -> Data {
        guard payload.count <= 65_536 else { throw ExtensionPeerError.invalidRequest }
        let request = try JSONDecoder().decode(CompletionRequest.self, from: payload)
        guard (1...128).contains(request.words.count),
            (1...request.words.count).contains(request.index),
            request.words.allSatisfy({ $0.utf8.count <= 4_096 && !$0.utf8.contains(0) })
        else { throw ExtensionPeerError.invalidRequest }
        let words = Array(request.words.prefix(request.index).dropFirst())
        guard words.first == "usage" else { throw ExtensionPeerError.invalidRequest }
        let current = request.index < request.words.count ? request.words[request.index] : ""
        var node = try JSONDecoder().decode(
            ParserDocument.self, from: Data(UsageCommand._dumpHelp().utf8)
        ).command
        var route = ["usage"]
        var expected: String?
        var positionals: [String] = []
        for word in words.dropFirst() {
            if expected != nil { expected = nil; continue }
            if word == "--" { return try result([], prefix: current) }
            if let child = node.children.first(where: { $0.names.contains(word) }) {
                node = child; route.append(child.commandName); positionals = []; continue
            }
            let option = String(word.split(separator: "=", maxSplits: 1).first ?? "")
            if let argument = node.effectiveOptions.first(where: { $0.options.contains(option) }) {
                if argument.kind == "option", !word.contains("=") { expected = option }
                continue
            }
            if !word.hasPrefix("-") {
                if let next = node.defaultCommand { node = next; route.append(next.commandName) }
                positionals.append(word)
            }
        }
        if let expected { return try values(expected, route: route, prefix: current) }
        if let separator = current.firstIndex(of: "=") {
            let option = String(current[..<separator])
            let prefix = String(current[current.index(after: separator)...])
            return try values(option, route: route, prefix: prefix, optionPrefix: option + "=")
        }
        if current.hasPrefix("-") {
            return try result(node.effectiveOptions.flatMap(\.options), prefix: current)
        }
        if positionals.isEmpty {
            let path = route.dropFirst().joined(separator: " ")
            let document = try? UsageDocument.load()
            var candidates = node.children.flatMap(\.names)
            if path.hasPrefix("machines ") { candidates += machineNames() }
            if ["projects show", "projects open", "projects copy-link"].contains(path) {
                candidates += UsageAnalysis.projectSelectors(document?.daily ?? [])
            }
            if path == "projects copy-chat" {
                candidates += UsageAnalysis.chatIDs(document?.daily ?? [])
            }
            return try result(candidates, prefix: current)
        }
        return try result([], prefix: current)
    }

    private static func values(
        _ option: String, route: [String], prefix: String, optionPrefix: String = ""
    ) throws -> Data {
        let candidates: [String]
        switch option {
        case "--range": candidates = UsageRange.allCases.map(\.rawValue)
        case "--card": candidates = UsageShareCard.allCases.map(\.rawValue) + ["all"]
        case "--source": candidates = (try? UsageDocument.load().sources?.sorted()) ?? []
        case "--machine": candidates = machineNames()
        default: candidates = []
        }
        return try result(
            candidates, prefix: prefix, optionPrefix: optionPrefix,
            wantsFiles: ["--output", "-o", "--input", "--settings"].contains(option))
    }

    private static func machineNames() -> [String] {
        UsageCLIEnvironment.machines().flatMap { machine in
            if case let .sshConfigAlias(alias) = machine.source { return [machine.name, alias] }
            return [machine.name]
        }
    }

    private static func result(
        _ candidates: [String], prefix: String, optionPrefix: String = "", wantsFiles: Bool = false
    ) throws -> Data {
        var seen: Set<String> = []
        let values = candidates.filter { $0.hasPrefix(prefix) && seen.insert($0).inserted }
        return try JSONSerialization.data(withJSONObject: [
            "candidates": values.map { optionPrefix + $0 }, "wantsFiles": wantsFiles,
        ])
    }
}
