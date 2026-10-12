import EdithExtensionSupport
import EdithHostCore
import Foundation
import Observation

struct HostToolingStatus: Decodable, Equatable, Sendable {
    struct Tools: Decodable, Equatable, Sendable {
        let directory: String
        let linked: [String]
        let missing: [String]
        let onPath: Bool
        let bundled: Bool
    }
    struct Completion: Decodable, Equatable, Sendable, Identifiable {
        let shell: String
        let path: String
        let state: String
        var id: String { shell }
    }
    let tools: Tools
    let completions: [Completion]
    let fallbackSource: String

    static func decode(_ reply: ExtensionCLIReply) throws -> Self {
        try reply.validate()
        guard reply.exitCode == 0, reply.stdout.utf8.count <= 65_536 else {
            throw HostCLIError.rejected(
                reply.stderr.isEmpty ? "Could not read tooling status." : reply.stderr)
        }
        let result = try JSONDecoder().decode(Self.self, from: Data(reply.stdout.utf8))
        let names = result.tools.linked + result.tools.missing
        guard Set(names) == ["ed", "edith"], names.count == 2,
            result.completions.count <= 3,
            Set(result.completions.map(\.shell)).count == result.completions.count,
            result.completions.allSatisfy({
                ["zsh", "bash", "fish"].contains($0.shell)
                    && ["missing", "current", "stale"].contains($0.state)
                    && !$0.path.isEmpty && $0.path.utf8.count <= 4096 && !$0.path.utf8.contains(0)
            }), !result.tools.directory.isEmpty, result.tools.directory.utf8.count <= 4096,
            !result.tools.directory.utf8.contains(0), result.fallbackSource.utf8.count <= 8192,
            !result.fallbackSource.utf8.contains(0)
        else { throw HostCLIError.rejected("Invalid tooling status.") }
        return result
    }
}

@MainActor @Observable final class HostToolingSettingsModel {
    enum Action: Equatable { case installTools, removeTools, installCompletions, copySourceLine }
    struct Outcome: Equatable {
        let action: Action
        let succeeded: Bool
        let message: String
    }
    typealias Execute = @Sendable ([String]) async throws -> ExtensionCLIReply
    static let autoRefreshKey = "completionsAutoRefresh"
    private let execute: Execute
    private let copy: (String) -> Void
    private let defaults: UserDefaults
    private var generation = 0
    private var work: Task<Void, Never>?
    private(set) var status: HostToolingStatus?
    private(set) var refreshing = false
    private(set) var running: Action?
    private(set) var outcome: Outcome?
    private(set) var error: String?
    var autoRefresh: Bool {
        didSet { defaults.set(autoRefresh, forKey: Self.autoRefreshKey) }
    }

    init(defaults: UserDefaults, execute: @escaping Execute, copy: @escaping (String) -> Void) {
        self.defaults = defaults
        self.execute = execute
        self.copy = copy
        autoRefresh = defaults.object(forKey: Self.autoRefreshKey) as? Bool ?? true
    }

    convenience init(
        defaults: UserDefaults, tooling: HostToolingCLI, copy: @escaping (String) -> Void
    ) {
        self.init(
            defaults: defaults,
            execute: { arguments in
                let task = Task.detached {
                    try Task.checkCancellation()
                    return try tooling.execute(arguments)
                }
                return try await withTaskCancellationHandler {
                    let result = try await task.value
                    try Task.checkCancellation()
                    return result
                } onCancel: {
                    task.cancel()
                }
            }, copy: copy)
    }

    var toolSummary: String {
        guard let tools = status?.tools else { return "Checking..." }
        guard tools.bundled else { return "not in this build" }
        guard !tools.linked.isEmpty else { return "not installed" }
        return tools.missing.isEmpty
            ? tools.linked.joined(separator: ", ")
            : "\(tools.linked.joined(separator: ", ")) (missing \(tools.missing.joined(separator: ", ")))"
    }

    var toolsHelp: String {
        guard let tools = status?.tools else {
            return "ed and edith are the same tool under two names."
        }
        if !tools.bundled { return "This build does not carry the ed launcher." }
        if !tools.onPath {
            return "\(tools.directory) is not on your PATH, so the shell cannot find ed yet."
        }
        return "ed and edith are the same tool under two names."
    }

    func refresh() async {
        guard !refreshing else { return }
        let token = generation
        refreshing = true
        defer { if token == generation { refreshing = false } }
        do {
            let found = try HostToolingStatus.decode(try await execute(["status", "--json"]))
            try Task.checkCancellation()
            guard token == generation else { return }
            status = found
            error = nil
        } catch {
            if token == generation, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func run(_ action: Action) {
        guard running == nil else { return }
        work?.cancel()
        work = Task { await perform(action) }
    }

    func perform(_ action: Action) async {
        guard running == nil else { return }
        let token = generation
        running = action
        outcome = nil
        defer { if token == generation { running = nil } }
        do {
            let message: String
            if action == .copySourceLine {
                guard let source = status?.fallbackSource, !source.isEmpty else {
                    throw HostCLIError.rejected(
                        "Refresh tooling status before copying its source line.")
                }
                try Task.checkCancellation()
                copy(source)
                message = "Copied the line to the clipboard."
            } else {
                let arguments: [String] =
                    switch action {
                    case .installTools: ["install", "--json"]
                    case .removeTools: ["uninstall", "--json"]
                    case .installCompletions: ["completions", "install", "--json"]
                    case .copySourceLine: []
                    }
                let reply = try await execute(arguments)
                try Task.checkCancellation()
                guard token == generation else { return }
                message = try Self.actionMessage(reply, action: action)
                await refresh()
            }
            try Task.checkCancellation()
            guard token == generation else { return }
            outcome = Outcome(action: action, succeeded: true, message: message)
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            if action != .copySourceLine { await refresh() }
            guard token == generation, !Task.isCancelled else { return }
            outcome = Outcome(action: action, succeeded: false, message: error.localizedDescription)
        }
    }

    func cancel() {
        generation += 1
        work?.cancel()
        work = nil
        refreshing = false
        running = nil
    }

    private static func actionMessage(_ reply: ExtensionCLIReply, action: Action) throws -> String {
        try reply.validate()
        guard reply.stdout.utf8.count <= 65_536 else {
            throw HostCLIError.rejected("Invalid tooling response.")
        }
        if action == .installCompletions {
            struct Result: Decodable {
                struct Failure: Decodable { let shell: String; let message: String }
                struct Installed: Decodable { let shell: String; let path: String }
                let installed: [Installed]
                let failures: [Failure]
                let succeeded: Bool
            }
            let result = try JSONDecoder().decode(Result.self, from: Data(reply.stdout.utf8))
            guard reply.exitCode == 0, result.succeeded, result.failures.isEmpty else {
                let detail = result.failures.map { "\($0.shell): \($0.message)" }.joined(
                    separator: "; ")
                throw HostCLIError.rejected(
                    detail.isEmpty
                        ? reply.stderr : "Could not install every completion script: \(detail)")
            }
            return
                "Wrote \(result.installed.count) completion \(result.installed.count == 1 ? "script" : "scripts"). Restart your shell to load them."
        }
        guard reply.exitCode == 0 else {
            throw HostCLIError.rejected(
                reply.stderr.isEmpty ? "The tooling action failed." : reply.stderr)
        }
        struct Result: Decodable {
            let directory: String; let linked: [String]?; let removed: [String]?
        }
        let result = try JSONDecoder().decode(Result.self, from: Data(reply.stdout.utf8))
        let names = action == .installTools ? result.linked : result.removed
        guard let names, names.count <= 2, names.allSatisfy({ ["ed", "edith"].contains($0) }) else {
            throw HostCLIError.rejected("Invalid tooling response.")
        }
        return names.isEmpty
            ? (action == .installTools
                ? "Already installed in \(result.directory)." : "Nothing to remove.")
            : "\(action == .installTools ? "Linked" : "Removed") \(names.joined(separator: ", "))\(action == .installTools ? " in " + result.directory : "")."
    }
}
