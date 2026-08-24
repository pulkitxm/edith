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

    public init(
        candidates: [String] = [], wantsFiles: Bool = false, remoteMachine: String? = nil
    ) {
        self.candidates = candidates
        self.wantsFiles = wantsFiles
        self.remoteMachine = remoteMachine
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
        quinjetSessions: [String] = []
    ) -> CompletionResult {
        let leading = ArgumentRewriting.completionOrder(request.leading)
        let prefix = request.current
        if let first = leading.first, CommandTree.root.child(first) == nil,
            machines.contains(where: { $0.lowercased() == first.lowercased() })
        {
            return CompletionResult(remoteMachine: first)
        }
        var node = CommandTree.root
        var positionals: [String] = []
        var expectedValue: ArgumentKind?
        for word in leading {
            if expectedValue != nil {
                expectedValue = nil
                continue
            }
            if let separator = word.firstIndex(of: "=") {
                let option = String(word[..<separator])
                if node.optionValues[option] != nil { continue }
            }
            if let kind = node.optionValues[word] {
                expectedValue = kind
                continue
            }
            if word.hasPrefix("-") { continue }
            if let next = node.child(word) {
                node = next
                positionals = []
                continue
            }
            positionals.append(word)
        }
        if let kind = expectedValue {
            return CompletionResult(
                candidates: filtered(
                    values(
                        for: kind, machines: machines, configKeys: configKeys,
                        extensionIDs: extensionIDs, toolIDs: toolIDs, usageSources: usageSources,
                        appLinks: appLinks, previous: positionals.last, shelfItems: shelfItems,
                        musicTracks: musicTracks, calendarEvents: calendarEvents,
                        runningApps: runningApps, quinjetSessions: quinjetSessions), prefix))
        }
        if let separator = prefix.firstIndex(of: "=") {
            let option = String(prefix[..<separator])
            if let kind = node.optionValues[option] {
                let valuePrefix = String(prefix[prefix.index(after: separator)...])
                let candidates = filtered(
                    values(
                        for: kind, machines: machines, configKeys: configKeys,
                        extensionIDs: extensionIDs, toolIDs: toolIDs, usageSources: usageSources,
                        appLinks: appLinks, previous: positionals.last, shelfItems: shelfItems,
                        musicTracks: musicTracks, calendarEvents: calendarEvents,
                        runningApps: runningApps, quinjetSessions: quinjetSessions), valuePrefix)
                return CompletionResult(candidates: candidates.map { option + "=" + $0 })
            }
        }
        if prefix.hasPrefix("-") {
            return CompletionResult(
                candidates: filtered(node.options + CommandTree.inherited, prefix))
        }
        var candidates = node.children.map(\.name)
        if node.name == "ed" {
            candidates += machines
        }
        var wantsFiles = false
        let slot = positionals.count
        if slot < node.arguments.count {
            let kind = node.arguments[slot]
            let values = values(
                for: kind, machines: machines, configKeys: configKeys,
                extensionIDs: extensionIDs, toolIDs: toolIDs, usageSources: usageSources,
                appLinks: appLinks, previous: positionals.last, shelfItems: shelfItems,
                musicTracks: musicTracks, calendarEvents: calendarEvents,
                runningApps: runningApps, quinjetSessions: quinjetSessions)
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
        quinjetSessions: [String] = []
    ) -> [String] {
        switch kind {
        case .machine: return machines
        case .appPath: return AppPathID.allCases.map(\.rawValue)
        case .appLink: return appLinks
        case .configKey: return configKeys
        case .configValue:
            guard let previous, let definition = ConfigCatalog.definition(for: previous) else {
                return []
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
        case .downloadKind: return DownloadKind.allCases.map(\.rawValue)
        case .musicPlayer: return MusicPlayer.allCases.map(\.rawValue)
        case .quinjetAppearance: return QuinjetAppearance.allCases.map(\.rawValue)
        case .quinjetMachine: return ["local"] + machines
        case .quinjetPath: return []
        case .quinjetSession: return quinjetSessions
        case .quinjetTheme: return QuinjetTheme.allCases.map(\.rawValue)
        case .pruneTarget: return DockerPruneCommand.targets
        case .shelfItem: return shelfItems
        case .musicTrack: return musicTracks
        case .calendarEvent: return calendarEvents
        case .tool: return toolIDs
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
