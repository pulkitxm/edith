import ArgumentParser
import EdithExtensionSupport
import Foundation

public struct CompletionRequest: Equatable, Sendable {
    public let words: [String]
    public let index: Int

    public init(words: [String], index: Int) {
        self.words = words
        self.index = max(0, index)
    }

    public var current: String {
        index < words.count ? words[index] : ""
    }

    public var leading: [String] {
        Array(words.prefix(index).dropFirst())
    }

    public static func stripSeparator(_ words: [String]) -> [String] {
        guard words.first == "--" else { return words }
        return Array(words.dropFirst())
    }
}

public struct CompletionResult: Equatable, Sendable {
    public var candidates: [String]
    public var wantsFiles: Bool
    public var remoteMachine: String?
    public var remoteRequest: CompletionRequest?

    public init(
        candidates: [String] = [], wantsFiles: Bool = false, remoteMachine: String? = nil,
        remoteRequest: CompletionRequest? = nil
    ) {
        self.candidates = candidates
        self.wantsFiles = wantsFiles
        self.remoteMachine = remoteMachine
        self.remoteRequest = remoteRequest
    }

    public var lines: [String] {
        (wantsFiles ? ["#files"] : []) + candidates
    }
}

public enum CompletionEngine {
    public static func plan(_ request: CompletionRequest, machines: [String]) -> CompletionResult {
        var leading = request.leading
        let prefix = request.current
        let grouped = leading.first == "machines"
        if grouped { leading.removeFirst() }
        let helpRoute = leading.first == "help"
        if helpRoute { leading.removeFirst() }
        if let first = leading.first,
            machines.contains(where: { $0.lowercased() == first.lowercased() })
        {
            let remaining = Array(leading.dropFirst())
            if !grouped, !prefix.hasPrefix("-") || !remaining.isEmpty {
                return CompletionResult(remoteMachine: first, remoteRequest: request)
            }
            if !grouped, remaining.isEmpty, !prefix.hasPrefix("-") {
                return CompletionResult(remoteMachine: first, remoteRequest: request)
            }
            if let word = remaining.first,
                MachineCLIArguments(MachinesCommand.self).child(word) == nil, !word.hasPrefix("-")
            {
                return CompletionResult(remoteMachine: first, remoteRequest: request)
            }
            if !remaining.isEmpty { leading = MachineCLIArguments.rewrite(leading) }
        }
        let machineRoute = true
        var node = CommandTree.root
        var command: ParsableCommand.Type = MachinesCommand.self
        var positionals: [String] = []
        var expectedValue: ArgumentKind?
        var optionValues = effectiveOptionValues(node: node, command: command)
        for (offset, word) in leading.enumerated() {
            if let result = passthroughResult(
                node: node, positionals: positionals, remaining: leading.dropFirst(offset),
                prefix: prefix)
            {
                return result
            }
            if word == "--" { return CompletionResult() }
            if expectedValue != nil {
                expectedValue = nil
                continue
            }
            if let separator = word.firstIndex(of: "=") {
                let option = String(word[..<separator])
                if optionValues[option] != nil {
                    selectDefaultRoute(
                        for: option, node: &node, command: &command,
                        optionValues: &optionValues, enabled: !helpRoute)
                    continue
                }
            }
            if let kind = optionValues[word] {
                selectDefaultRoute(
                    for: word, node: &node, command: &command,
                    optionValues: &optionValues, enabled: !helpRoute)
                expectedValue = kind
                continue
            }
            if word.hasPrefix("-") {
                selectDefaultRoute(
                    for: word, node: &node, command: &command,
                    optionValues: &optionValues, enabled: !helpRoute)
                continue
            }
            if let next = node.child(word) {
                node = next
                if let nextCommand = parserChild(word, in: command) { command = nextCommand }
                optionValues = effectiveOptionValues(node: node, command: command)
                positionals = []
                continue
            }
            let keepsMachineFirstRoute =
                machineRoute && positionals.isEmpty
                && machines.contains(where: { $0.lowercased() == word.lowercased() })
            selectDefaultRoute(
                for: nil, node: &node, command: &command, optionValues: &optionValues,
                enabled: !helpRoute && !keepsMachineFirstRoute)
            positionals.append(word)
        }
        if let result = passthroughResult(
            node: node, positionals: positionals, remaining: [], prefix: prefix)
        {
            return result
        }
        if let kind = expectedValue {
            return CompletionResult(
                candidates: filtered(
                    values(for: kind, machines: machines), prefix),
                wantsFiles: kind == .localPath)
        }
        if let separator = prefix.firstIndex(of: "=") {
            let option = String(prefix[..<separator])
            if let kind = optionValues[option] {
                let valuePrefix = String(prefix[prefix.index(after: separator)...])
                let candidates = filtered(
                    values(for: kind, machines: machines), valuePrefix
                )
                return CompletionResult(candidates: candidates.map { option + "=" + $0 })
            }
        }
        if prefix.hasPrefix("-") {
            let options =
                helpRoute ? CommandTree.inherited : effectiveOptions(node: node, command: command)
            return CompletionResult(
                candidates: filtered(options, prefix))
        }
        var candidates: [String] = []
        candidates += node.children.flatMap(\.names)
        var wantsFiles = false
        let slot = positionals.count
        let arguments =
            helpRoute
            ? [] : effectiveArguments(node: node, command: command)
        let repeatingArgument =
            helpRoute
            ? nil
            : node.repeatingArgument ?? defaultNode(node: node, command: command)?.repeatingArgument
        if let kind = slot < arguments.count ? arguments[slot] : repeatingArgument {
            let values = values(for: kind, machines: machines)
            candidates += values
            if kind == .localPath { wantsFiles = true }

        }
        return CompletionResult(
            candidates: filtered(candidates, prefix), wantsFiles: wantsFiles)
    }

    static func values(for kind: ArgumentKind, machines: [String]) -> [String] {
        switch kind {
        case .machine: return machines
        case .machineOrLocal: return ["local", "this-mac", "thismac"] + machines
        case .onOff: return ["on", "off"]
        case .pruneTarget: return DockerPruneCommand.targets
        case .localPath, .remotePath, .container, .composeProject, .historyIndex, .free: return []
        }
    }

    static func filtered(_ values: [String], _ prefix: String) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard value.hasPrefix(prefix), seen.insert(value).inserted else { return false }
            return true
        }
    }

    private static func parserChild(_ name: String, in command: ParsableCommand.Type)
        -> ParsableCommand.Type?
    {
        command.configuration.subcommands.first {
            $0.configuration.commandName == name || $0.configuration.aliases.contains(name)
        }
    }

    private static func defaultNode(node: CommandNode, command: ParsableCommand.Type)
        -> CommandNode?
    {
        guard let fallback = command.configuration.defaultSubcommand,
            let name = fallback.configuration.commandName
        else { return nil }
        return node.child(name)
    }

    private static func defaultRoute(node: CommandNode, command: ParsableCommand.Type)
        -> (node: CommandNode, command: ParsableCommand.Type)?
    {
        guard let fallback = command.configuration.defaultSubcommand,
            let fallbackNode = defaultNode(node: node, command: command)
        else { return nil }
        return (fallbackNode, fallback)
    }

    private static func selectDefaultRoute(
        for option: String?, node: inout CommandNode, command: inout ParsableCommand.Type,
        optionValues: inout [String: ArgumentKind], enabled: Bool
    ) {
        guard enabled, let route = defaultRoute(node: node, command: command) else { return }
        if let option {
            guard route.node.options.contains(option), !parserOptionNames(command).contains(option)
            else { return }
        }
        node = route.node
        command = route.command
        optionValues = effectiveOptionValues(node: node, command: command)
    }

    private static func passthroughResult(
        node: CommandNode, positionals: [String], remaining: ArraySlice<String>, prefix: String
    ) -> CompletionResult? {
        guard let passthrough = node.passthroughCompletion,
            positionals.count >= passthrough.afterPositionals
        else { return nil }
        guard let machinePosition = passthrough.remoteMachinePosition,
            machinePosition < positionals.count
        else { return CompletionResult() }
        var payload = Array(remaining)
        if payload.first == "--" { payload.removeFirst() }
        let words = ["ed", positionals[machinePosition]] + payload + [prefix]
        return CompletionResult(
            remoteMachine: positionals[machinePosition],
            remoteRequest: CompletionRequest(words: words, index: words.count - 1))
    }

    private static func effectiveOptions(node: CommandNode, command: ParsableCommand.Type)
        -> [String]
    {
        node.options + (defaultNode(node: node, command: command)?.options ?? [])
            + CommandTree.inherited
    }

    private static func effectiveOptionValues(
        node: CommandNode, command: ParsableCommand.Type
    ) -> [String: ArgumentKind] {
        var values = parserOptionValues(command)
        if let fallback = command.configuration.defaultSubcommand {
            values.merge(parserOptionValues(fallback)) { _, fallbackValue in fallbackValue }
        }
        values.merge(defaultNode(node: node, command: command)?.optionValues ?? [:]) {
            _, typedValue in typedValue
        }
        values.merge(node.optionValues) { _, nodeValue in nodeValue }
        return values
    }

    private static func parserOptionValues(_ command: ParsableCommand.Type)
        -> [String: ArgumentKind]
    {
        var values: [String: ArgumentKind] = [:]
        for line in command.helpMessage(columns: 400).split(separator: "\n") {
            guard line.hasPrefix("  -"), !line.hasPrefix("   ") else { continue }
            let declaration = line.dropFirst(2)
                .split(separator: " ", omittingEmptySubsequences: false)
                .prefix { !$0.isEmpty }
            guard declaration.contains(where: { $0.contains("<") }) else { continue }
            for token in declaration where token.hasPrefix("-") {
                let option = token.prefix { $0 != "," && $0 != "<" && $0 != "=" }
                if option.count > 1 { values[String(option)] = .free }
            }
        }
        return values
    }

    private static func parserOptionNames(_ command: ParsableCommand.Type) -> Set<String> {
        Set(
            command.helpMessage(columns: 400).split(separator: "\n").flatMap { line -> [String] in
                guard line.hasPrefix("  -"), !line.hasPrefix("   ") else { return [] }
                let declaration = line.dropFirst(2)
                    .split(separator: " ", omittingEmptySubsequences: false)
                    .prefix { !$0.isEmpty }
                return declaration.compactMap { token in
                    guard token.hasPrefix("-") else { return nil }
                    let option = token.prefix { $0 != "," && $0 != "<" && $0 != "=" }
                    return option.count > 1 ? String(option) : nil
                }
            })
    }

    private static func effectiveArguments(node: CommandNode, command: ParsableCommand.Type)
        -> [ArgumentKind]
    {
        node.arguments.isEmpty
            ? defaultNode(node: node, command: command)?.arguments ?? [] : node.arguments
    }

}
