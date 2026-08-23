import EdithCore
import Foundation

public enum QuinjetTerminal: String, CaseIterable, Identifiable, Sendable {
    case embedded
    case cmux

    public var id: String { rawValue }
}

public enum QuinjetTheme: String, CaseIterable, Identifiable, Sendable {
    case quinjet
    case catppuccin
    case dracula
    case everforest
    case gruvbox
    case nord
    case one
    case rosePine = "rose-pine"
    case solarized
    case tokyoNight = "tokyo-night"
    case ayu
    case monokai
    case github

    public var id: String { rawValue }
}

public enum QuinjetAppearance: String, CaseIterable, Sendable {
    case light
    case dark
}

public struct QuinjetLaunchConfiguration: Equatable, Sendable {
    public var terminal: QuinjetTerminal
    public var theme: QuinjetTheme
    public var appearance: QuinjetAppearance

    public init(
        terminal: QuinjetTerminal, theme: QuinjetTheme, appearance: QuinjetAppearance
    ) {
        self.terminal = terminal
        self.theme = theme
        self.appearance = appearance
    }

    public static let `default` = QuinjetLaunchConfiguration(
        terminal: .embedded, theme: .quinjet, appearance: .dark)

    public static func preferred(
        sharedDefaults: UserDefaults, standardDefaults: UserDefaults
    ) -> QuinjetLaunchConfiguration {
        let terminal =
            QuinjetTerminal(
                rawValue: sharedDefaults.string(forKey: AppStorageKeys.Quinjet.terminal) ?? "")
            ?? .embedded
        let theme =
            QuinjetTheme(
                rawValue: sharedDefaults.string(forKey: AppStorageKeys.Quinjet.theme) ?? "")
            ?? .quinjet
        let appearance: QuinjetAppearance
        switch sharedDefaults.string(forKey: AppStorageKeys.General.appearance) {
        case "light": appearance = .light
        case "dark": appearance = .dark
        default:
            appearance =
                standardDefaults.string(forKey: "AppleInterfaceStyle") == "Dark"
                ? .dark : .light
        }
        return QuinjetLaunchConfiguration(
            terminal: terminal, theme: theme, appearance: appearance)
    }
}

public struct QuinjetLaunchRequest: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let currentDirectory: String?
    public let terminal: QuinjetTerminal

    public init(
        executableURL: URL, arguments: [String], currentDirectory: String?,
        terminal: QuinjetTerminal
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.terminal = terminal
    }

    public init(
        executableURL: URL, worktreePath: String, remote: QuinjetRemote?,
        configuration: QuinjetLaunchConfiguration, managedByEdith: Bool,
        localHomeDirectory: String
    ) {
        var arguments: [String] = []
        if managedByEdith { arguments += ["--client", "edith"] }
        if let remote {
            arguments += [
                "--remote", remote.target, "--ssh-control-path", remote.controlPath,
            ]
        }
        arguments += ["-C", worktreePath, "tui"]
        arguments += [
            "--theme", configuration.theme.rawValue,
            "--appearance", configuration.appearance.rawValue,
        ]
        self.executableURL = executableURL
        self.arguments = arguments
        self.terminal = configuration.terminal
        switch (configuration.terminal, remote) {
        case (.embedded, .some): currentDirectory = nil
        case (.cmux, .some): currentDirectory = localHomeDirectory
        case (_, .none): currentDirectory = worktreePath
        }
    }

    public var shellCommand: String {
        QuinjetShellCommand.make(
            executable: executableURL.path, arguments: arguments,
            currentDirectory: currentDirectory)
    }
}

public enum QuinjetShellCommand {
    public static func make(
        executable: String, arguments: [String], currentDirectory: String? = nil
    ) -> String {
        let launch = "exec " + ([executable] + arguments).map(quote).joined(separator: " ")
        guard let currentDirectory else { return launch }
        return "cd \(quote(currentDirectory)) && \(launch)"
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum QuinjetCMUX {
    public static func executable(fileManager: FileManager = .default) -> URL? {
        let candidates = [
            "/Applications/cmux.app/Contents/Resources/bin/cmux",
            "/Applications/cmux.app/Contents/MacOS/cmux",
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    public static func launchScript(
        request: QuinjetLaunchRequest, replacing workspaceID: String? = nil
    ) -> String {
        var statements = ["tell application id \"com.cmuxterm.app\"", "activate"]
        if let workspaceID { statements += closeStatements(workspaceID: workspaceID) }
        statements += [
            "set quinjetWorkspace to new tab",
            "select tab quinjetWorkspace",
            "delay 0.5",
            "set quinjetTerminal to focused terminal of quinjetWorkspace",
            "focus quinjetTerminal",
            "input text \(appleScriptQuote(request.shellCommand)) to quinjetTerminal",
            "perform action \(appleScriptQuote("text:\\x0d")) on quinjetTerminal",
            "return id of quinjetWorkspace",
            "end tell",
        ]
        return statements.joined(separator: "\n")
    }

    public static func focusScript(workspaceID: String) -> String {
        [
            "tell application id \"com.cmuxterm.app\"", "activate",
            "repeat with cmuxWindow in windows",
            "repeat with cmuxWorkspace in tabs of cmuxWindow",
            "if id of cmuxWorkspace is \(appleScriptQuote(workspaceID)) then",
            "select tab cmuxWorkspace", "return id of cmuxWorkspace", "end if", "end repeat",
            "end repeat", "error \"workspace is no longer open\"", "end tell",
        ].joined(separator: "\n")
    }

    public static func closeScript(workspaceID: String) -> String {
        (["tell application id \"com.cmuxterm.app\""]
            + closeStatements(workspaceID: workspaceID) + ["return \"closed\"", "end tell"])
            .joined(separator: "\n")
    }

    public static func appleScriptQuote(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static func closeStatements(workspaceID: String) -> [String] {
        [
            "repeat with cmuxWindow in windows",
            "repeat with cmuxWorkspace in tabs of cmuxWindow",
            "if id of cmuxWorkspace is \(appleScriptQuote(workspaceID)) then",
            "close tab cmuxWorkspace", "exit repeat", "end if", "end repeat", "end repeat",
        ]
    }
}

public enum QuinjetOperation: String, CaseIterable, Equatable, Sendable {
    case projects
    case worktrees
    case open
    case launch

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .projects:
            descriptor("List recent Quinjet projects.", effect: .read)
        case .worktrees:
            descriptor("List the worktrees in a Quinjet project.", effect: .read)
        case .open:
            descriptor("Print a Quinjet launch request without running it.", effect: .read)
        case .launch:
            descriptor("Launch a Quinjet review session.", effect: .interactive)
        }
    }

    private func descriptor(
        _ summary: String, effect: UserOperationEffect
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "quinjet.\(rawValue)"), summary: summary,
            cli: ["quinjet", rawValue], effect: effect)
    }
}

public enum QuinjetOperationExecution {
    public static func projects(
        remote: QuinjetRemote? = nil, using client: QuinjetClient
    ) async throws -> [QuinjetProject] {
        if let remote { return try await client.recentProjects(remote: remote) }
        return try await client.recentProjects()
    }

    public static func worktrees(
        at path: String, remote: QuinjetRemote? = nil, using client: QuinjetClient
    ) async throws -> [QuinjetWorktree] {
        try await client.worktrees(at: path, remote: remote)
    }

    public static func openSelection(
        at path: String, remote: QuinjetRemote? = nil, using client: QuinjetClient
    ) async throws -> QuinjetOpenSelection {
        let worktrees = try await worktrees(at: path, remote: remote, using: client).filter(
            \.canOpen)
        guard let worktree = worktrees.first(where: { $0.path == path }) ?? worktrees.first else {
            throw QuinjetOperationError.noOpenWorktree(path)
        }
        return QuinjetOpenSelection(
            projectName: URL(fileURLWithPath: path).lastPathComponent,
            worktree: worktree, worktrees: worktrees)
    }

    public static func launchRequest(
        executableURL: URL, worktreePath: String, remote: QuinjetRemote?,
        configuration: QuinjetLaunchConfiguration, managedByEdith: Bool,
        localHomeDirectory: String
    ) -> QuinjetLaunchRequest {
        QuinjetLaunchRequest(
            executableURL: executableURL, worktreePath: worktreePath, remote: remote,
            configuration: configuration, managedByEdith: managedByEdith,
            localHomeDirectory: localHomeDirectory)
    }
}
