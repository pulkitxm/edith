import EdithCore
import Foundation

public enum TerminalToolingOperation: String, CaseIterable, Sendable {
    case status
    case install
    case remove
    case completionInstall = "completion-install"
    case fallbackSource = "fallback-source"

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "terminal-tooling.\(rawValue)"),
            summary: summary, cli: cli, effect: effect)
    }

    private var cli: [String] {
        switch self {
        case .status: ["status"]
        case .install: ["install"]
        case .remove: ["uninstall"]
        case .completionInstall: ["completions", "install"]
        case .fallbackSource: ["completions", "source"]
        }
    }

    private var summary: String {
        switch self {
        case .status: "Inspect command-line tools and shell completions."
        case .install: "Install the Edith command-line tools."
        case .remove: "Remove the Edith command-line tools."
        case .completionInstall: "Install shell completion scripts."
        case .fallbackSource: "Print the fallback shell completion source line."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .status, .fallbackSource: .read
        case .install, .remove, .completionInstall: .write
        }
    }
}

public struct TerminalToolingSnapshot: Equatable, Sendable {
    public var tools: CLIToolStatus
    public var completions: [CompletionStatus]
    public var fallbackSourceLine: String

    public init(
        tools: CLIToolStatus, completions: [CompletionStatus], fallbackSourceLine: String
    ) {
        self.tools = tools
        self.completions = completions
        self.fallbackSourceLine = fallbackSourceLine
    }
}

public struct TerminalToolMutationOutcome: Equatable, Sendable {
    public var result: CLIInstallResult
    public var onPath: Bool

    public init(result: CLIInstallResult, onPath: Bool) {
        self.result = result
        self.onPath = onPath
    }

    public var succeeded: Bool { result.message == nil }
}

public struct TerminalCompletionInstallation: Equatable, Sendable {
    public var shell: CompletionScripts.Shell
    public var path: URL
    public var hint: String?

    public init(shell: CompletionScripts.Shell, path: URL, hint: String?) {
        self.shell = shell
        self.path = path
        self.hint = hint
    }
}

public struct TerminalCompletionFailure: Equatable, Sendable {
    public var shell: CompletionScripts.Shell
    public var message: String

    public init(shell: CompletionScripts.Shell, message: String) {
        self.shell = shell
        self.message = message
    }
}

public struct TerminalCompletionInstallOutcome: Equatable, Sendable {
    public var installed: [TerminalCompletionInstallation]
    public var failures: [TerminalCompletionFailure]

    public init(
        installed: [TerminalCompletionInstallation], failures: [TerminalCompletionFailure]
    ) {
        self.installed = installed
        self.failures = failures
    }

    public var succeeded: Bool { failures.isEmpty }
}

public enum TerminalToolingOperationExecution {
    public static func status(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: UserDefaults = SharedDefaults.store, fileManager: FileManager = .default
    ) -> TerminalToolingSnapshot {
        TerminalToolingSnapshot(
            tools: CLIInstaller.status(
                home: home, environment: environment, fileManager: fileManager),
            completions: CompletionScripts.statuses(
                home: home, store: store, fileManager: fileManager),
            fallbackSourceLine: fallbackSource(
                for: .zsh, home: home, store: store, fileManager: fileManager))
    }

    public static func install(
        toolsDirectory: URL? = nil, into directory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> TerminalToolMutationOutcome {
        let result = CLIInstaller.install(
            toolsDirectory: toolsDirectory, into: directory, fileManager: fileManager)
        let onPath =
            !result.directory.isEmpty
            && CLIInstaller.isOnPath(
                URL(fileURLWithPath: result.directory),
                entries: CLIInstaller.pathEntries(environment))
        return TerminalToolMutationOutcome(result: result, onPath: onPath)
    }

    public static func remove(
        from directory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> TerminalToolMutationOutcome {
        let result = CLIInstaller.uninstall(from: directory, fileManager: fileManager)
        let onPath = CLIInstaller.isOnPath(
            URL(fileURLWithPath: result.directory), entries: CLIInstaller.pathEntries(environment))
        return TerminalToolMutationOutcome(result: result, onPath: onPath)
    }

    public static func installCompletions(
        shells: [CompletionScripts.Shell]? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        store: UserDefaults = SharedDefaults.store, fileManager: FileManager = .default
    ) -> TerminalCompletionInstallOutcome {
        let selected =
            shells ?? CompletionScripts.detectShells(home: home, fileManager: fileManager)
        var installed: [TerminalCompletionInstallation] = []
        var failures: [TerminalCompletionFailure] = []
        for shell in selected {
            do {
                let file = try CompletionScripts.install(
                    shell, home: home, fileManager: fileManager, store: store)
                installed.append(
                    TerminalCompletionInstallation(
                        shell: shell, path: file,
                        hint: CompletionScripts.rcHint(
                            for: shell, directory: file.deletingLastPathComponent())))
            } catch {
                failures.append(
                    TerminalCompletionFailure(
                        shell: shell, message: error.localizedDescription))
            }
        }
        return TerminalCompletionInstallOutcome(installed: installed, failures: failures)
    }

    public static func fallbackSource(
        for shell: CompletionScripts.Shell,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        store: UserDefaults = SharedDefaults.store, fileManager: FileManager = .default
    ) -> String {
        CompletionScripts.sourceLine(
            for: shell, home: home, store: store, fileManager: fileManager)
    }
}
