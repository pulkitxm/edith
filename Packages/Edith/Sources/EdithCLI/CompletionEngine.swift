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
        extensionIDs: [String]
    ) -> CompletionResult {
        let leading = ArgumentRewriting.completionOrder(request.leading)
        let prefix = request.current
        if let first = leading.first, CommandTree.root.child(first) == nil,
            machines.contains(where: { $0.lowercased() == first.lowercased() })
        {
            return CompletionResult(remoteMachine: first)
        }
        var node = CommandTree.root
        var consumed = 0
        for word in leading {
            guard !word.hasPrefix("-"), let next = node.child(word) else { break }
            node = next
            consumed += 1
        }
        if prefix.hasPrefix("-") {
            return CompletionResult(
                candidates: filtered(node.options + CommandTree.common, prefix))
        }
        var candidates = node.children.map(\.name)
        if node.name == "ed" {
            candidates += machines
        }
        var wantsFiles = false
        let positional = leading.dropFirst(consumed).filter { !$0.hasPrefix("-") }
        let slot = positional.count
        if slot < node.arguments.count {
            let kind = node.arguments[slot]
            let values = values(
                for: kind, machines: machines, configKeys: configKeys,
                extensionIDs: extensionIDs, previous: positional.last)
            candidates += values
            if kind == .localPath { wantsFiles = true }
        }
        return CompletionResult(
            candidates: filtered(candidates, prefix), wantsFiles: wantsFiles)
    }

    static func values(
        for kind: ArgumentKind, machines: [String], configKeys: [String], extensionIDs: [String],
        previous: String?
    ) -> [String] {
        switch kind {
        case .machine: return machines
        case .configKey: return configKeys
        case .configValue:
            guard let previous, let definition = ConfigCatalog.definition(for: previous) else {
                return []
            }
            if !definition.allowed.isEmpty { return definition.allowed }
            return definition.type == .bool ? ["true", "false"] : []
        case .extensionID: return extensionIDs
        case .permission: return ExtensionPermission.allCases.map(\.rawValue)
        case .shell: return ["zsh", "bash", "fish"]
        case .group: return ConfigCatalog.groups
        case .usageRange: return UsageRange.allCases.map(\.rawValue)
        case .appAction: return AppActions.all.map(\.name)
        case .cleanerCategory: return JunkCatalog.entries.map(\.id)
        case .colorFormat: return ColorCopyFormat.allCases.map(\.rawValue)
        case .pruneTarget: return DockerPruneCommand.targets
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
}
