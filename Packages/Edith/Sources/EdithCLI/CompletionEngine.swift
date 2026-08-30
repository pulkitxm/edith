import ArgumentParser
import EdithKit
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
    public static func plan(
        _ request: CompletionRequest, machines: [String], configKeys: [String],
        extensionIDs: [String], shelfItems: [String] = [], musicTracks: [String] = [],
        calendarEvents: [String] = [], toolIDs: [String] = ToolProvisioning.all.map(\.id),
        usageSources: [String] = [], runningApps: [String] = [],
        appLinks: [String] = ["repository", "creator"],
        usageChatIDs: [String] = [], usageProjects: [String] = [],
        quinjetSessions: [String] = []
    ) -> CompletionResult {
        var leading = ArgumentRewriting.completionOrder(request.leading)
        let prefix = request.current
        let helpRoute = leading.first == CommandTree.help.name
        if helpRoute { leading.removeFirst() }
        if let first = leading.first, CommandTree.root.child(first) == nil,
            machines.contains(where: { $0.lowercased() == first.lowercased() })
        {
            let localShow =
                prefix.hasPrefix("-")
                && leading.dropFirst().allSatisfy { $0.hasPrefix("-") }
            if localShow {
                leading = ["machines", "show", first] + leading.dropFirst()
            } else if !helpRoute {
                return CompletionResult(remoteMachine: first)
            }
        }
        let machineRoute = leading.first == ArgumentRewriting.machinesGroup
        var node = CommandTree.root
        var command: ParsableCommand.Type = EdRoot.self
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
        let guideCatalogSelected = node.name == "guide" && leading.contains("--json")
        let guideTopicSelected = node.name == "guide" && !positionals.isEmpty
        if let kind = expectedValue {
            return CompletionResult(
                candidates: filtered(
                    values(
                        for: kind, machines: machines, configKeys: configKeys,
                        extensionIDs: extensionIDs, toolIDs: toolIDs, usageSources: usageSources,
                        appLinks: appLinks, previous: positionals.last, shelfItems: shelfItems,
                        musicTracks: musicTracks, calendarEvents: calendarEvents,
                        runningApps: runningApps, usageChatIDs: usageChatIDs,
                        usageProjects: usageProjects, quinjetSessions: quinjetSessions), prefix),
                wantsFiles: kind == .localPath)
        }
        if let separator = prefix.firstIndex(of: "=") {
            let option = String(prefix[..<separator])
            if let kind = optionValues[option] {
                let valuePrefix = String(prefix[prefix.index(after: separator)...])
                let candidates = filtered(
                    values(
                        for: kind, machines: machines, configKeys: configKeys,
                        extensionIDs: extensionIDs, toolIDs: toolIDs, usageSources: usageSources,
                        appLinks: appLinks, previous: positionals.last, shelfItems: shelfItems,
                        musicTracks: musicTracks, calendarEvents: calendarEvents,
                        runningApps: runningApps, usageChatIDs: usageChatIDs,
                        usageProjects: usageProjects, quinjetSessions: quinjetSessions), valuePrefix
                )
                return CompletionResult(candidates: candidates.map { option + "=" + $0 })
            }
        }
        if prefix.hasPrefix("-") {
            var options =
                helpRoute ? CommandTree.inherited : effectiveOptions(node: node, command: command)
            if guideTopicSelected { options.removeAll { $0 == "--json" } }
            return CompletionResult(
                candidates: filtered(options, prefix))
        }
        var candidates = node.name == "ed" && !helpRoute ? [CommandTree.help.name] : []
        candidates += node.children.flatMap(\.names)
        if node.name == "ed" {
            if !helpRoute { candidates += machines }
        }
        var wantsFiles = false
        let slot = positionals.count
        let arguments =
            helpRoute || guideCatalogSelected
            ? [] : effectiveArguments(node: node, command: command)
        let repeatingArgument =
            helpRoute
            ? nil
            : node.repeatingArgument ?? defaultNode(node: node, command: command)?.repeatingArgument
        if let kind = slot < arguments.count ? arguments[slot] : repeatingArgument {
            let values = values(
                for: kind, machines: machines, configKeys: configKeys,
                extensionIDs: extensionIDs, toolIDs: toolIDs, usageSources: usageSources,
                appLinks: appLinks, previous: positionals.last, shelfItems: shelfItems,
                musicTracks: musicTracks, calendarEvents: calendarEvents,
                runningApps: runningApps, usageChatIDs: usageChatIDs,
                usageProjects: usageProjects,
                quinjetSessions: quinjetSessions)
            candidates += values
            if kind == .localPath { wantsFiles = true }
            if kind == .quinjetPath { wantsFiles = quinjetPathIsLocal(leading) }
        }
        return CompletionResult(
            candidates: filtered(candidates, prefix), wantsFiles: wantsFiles)
    }

    static func values(
        for kind: ArgumentKind, machines: [String], configKeys: [String], extensionIDs: [String],
        toolIDs: [String] = ToolProvisioning.all.map(\.id), usageSources: [String] = [],
        appLinks: [String] = ["repository", "creator"], previous: String?,
        shelfItems: [String] = [], musicTracks: [String] = [],
        calendarEvents: [String] = [], runningApps: [String] = [],
        usageChatIDs: [String] = [], usageProjects: [String] = [],
        quinjetSessions: [String] = []
    ) -> [String] {
        switch kind {
        case .machine: return machines
        case .machineOrLocal: return UsageMachineFilter.localNames + machines
        case .appPath: return AppPathID.allCases.map(\.rawValue)
        case .appLink: return appLinks
        case .guideTopic: return ["agent"]
        case .configKey: return configKeys
        case .configValue:
            guard let previous, let definition = ConfigCatalog.definition(for: previous) else {
                return []
            }
            if definition.key == AppStorageKeys.Quinjet.theme {
                return QuinjetTheme.allCases.map(\.rawValue)
            }
            if !definition.allowed.isEmpty { return definition.allowed }
            return definition.type == .bool ? ["true", "false"] : []
        case .extensionID: return extensionIDs
        case .toolID: return ToolProvisioning.all.map(\.id)
        case .permission: return ExtensionPermission.allCases.map(\.rawValue)
        case .onOff: return ["on", "off"]
        case .shell: return ["zsh", "bash", "fish"]
        case .group: return ConfigCatalog.groups
        case .usageRange: return UsageRange.allCases.map(\.rawValue)
        case .usageShareCard: return UsageShareCard.allCases.map(\.rawValue) + ["all"]
        case .attentionRange:
            return ["today", "yesterday", "24h", "7d", "30d", "week", "month", "all"]
        case .attentionCategory: return AttentionSettings.defaultCategories.map(\.id)
        case .attentionEntity: return []
        case .appAction: return AppActions.all.map(\.name)
        case .runningApp: return runningApps
        case .cleanerCategory: return JunkCatalog.entries.map(\.id)
        case .colorFormat: return ColorCopyFormat.allCases.map(\.rawValue)
        case .colorIndex:
            return ColorHistoryStore.load(from: CLIEnvironment.sharedDefaults).indices.map {
                String($0 + 1)
            }
        case .emojiTone: return EmojiSkinTone.allCases.map(\.token)
        case .emojiGroup: return EmojiCatalog.shared.groups.map(\.id)
        case .emojiCharacter:
            return EmojiCatalogSummary.frequent(store: CLIEnvironment.sharedDefaults)
        case .downloadKind: return DownloadKind.allCases.map(\.rawValue)
        case .musicPlayer: return MusicPlayer.allCases.map(\.rawValue)
        case .quinjetAppearance: return QuinjetAppearance.allCases.map(\.rawValue)
        case .quinjetMachine: return ["local"] + machines
        case .quinjetPath: return []
        case .quinjetSession: return quinjetSessions
        case .quinjetTheme: return QuinjetTheme.allCases.map(\.rawValue)
        case .pruneTarget: return DockerPruneCommand.targets
        case .shelfItem: return shelfItems
        case .shelfKeepDuration: return ShelfKeepDuration.allCases.map(\.rawValue)
        case .musicTrack: return musicTracks
        case .calendarEvent: return calendarEvents
        case .tool: return toolIDs
        case .usageChat: return usageChatIDs
        case .usageProject: return usageProjects
        case .usageSource: return usageSources
        case .localPath, .remotePath, .container, .composeProject, .historyIndex, .free:
            return []
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

    private static func quinjetPathIsLocal(_ words: [String]) -> Bool {
        if let assignment = words.last(where: { $0.hasPrefix("--machine=") }) {
            let machine = String(assignment.dropFirst("--machine=".count))
            return ["local", "this-mac", "thismac"].contains(machine.lowercased())
        }
        guard let option = words.lastIndex(of: "--machine"), option + 1 < words.count else {
            return true
        }
        return ["local", "this-mac", "thismac"].contains(words[option + 1].lowercased())
    }
}
