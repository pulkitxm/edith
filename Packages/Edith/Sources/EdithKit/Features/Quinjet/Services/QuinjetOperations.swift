import EdithCore
import Foundation

public enum QuinjetTerminal: String, CaseIterable, Identifiable, Sendable {
    case embedded
    case cmux

    public var id: String { rawValue }
}

public struct QuinjetTheme: RawRepresentable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public var id: String { rawValue }

    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue != QuinjetThemePreference.app else { return nil }
        self.rawValue = rawValue
    }

    private init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static let quinjet = Self("quinjet")
    public static let catppuccin = Self("catppuccin")
    public static let dracula = Self("dracula")
    public static let everforest = Self("everforest")
    public static let gruvbox = Self("gruvbox")
    public static let nord = Self("nord")
    public static let one = Self("one")
    public static let rosePine = Self("rose-pine")
    public static let solarized = Self("solarized")
    public static let tokyoNight = Self("tokyo-night")
    public static let ayu = Self("ayu")
    public static let monokai = Self("monokai")
    public static let github = Self("github")

    public static let allCases = [
        quinjet, catppuccin, dracula, everforest, gruvbox, nord, one, rosePine, solarized,
        tokyoNight, ayu, monokai, github,
    ]
}

public enum QuinjetThemePreference {
    public static let app = "app"

    public static func resolve(_ storedValue: String, appTheme: AppTheme) -> QuinjetTheme {
        if storedValue != app, let explicit = QuinjetTheme(rawValue: storedValue) {
            return explicit
        }
        switch appTheme {
        case .accent: return .quinjet
        case .blue: return .github
        case .indigo: return .tokyoNight
        case .teal: return .solarized
        case .green: return .everforest
        case .purple: return .dracula
        case .pink: return .rosePine
        case .red: return .monokai
        case .orange: return .ayu
        }
    }
}

public enum QuinjetAppearance: String, CaseIterable, Sendable {
    case light
    case dark
}

public struct QuinjetHostPalette: Equatable, Sendable {
    public let background: UInt32
    public let panel: UInt32
    public let panelAlt: UInt32
    public let border: UInt32
    public let muted: UInt32
    public let text: UInt32
    public let textStrong: UInt32
    public let contrast: UInt32
    public let removed: UInt32
    public let orange: UInt32
    public let modified: UInt32
    public let added: UInt32
    public let cyan: UInt32
    public let accent: UInt32
    public let purple: UInt32
    public let brown: UInt32

    public init(
        background: UInt32, panel: UInt32, panelAlt: UInt32, border: UInt32,
        muted: UInt32, text: UInt32, textStrong: UInt32, contrast: UInt32,
        removed: UInt32, orange: UInt32, modified: UInt32, added: UInt32,
        cyan: UInt32, accent: UInt32, purple: UInt32, brown: UInt32
    ) {
        self.background = background
        self.panel = panel
        self.panelAlt = panelAlt
        self.border = border
        self.muted = muted
        self.text = text
        self.textStrong = textStrong
        self.contrast = contrast
        self.removed = removed
        self.orange = orange
        self.modified = modified
        self.added = added
        self.cyan = cyan
        self.accent = accent
        self.purple = purple
        self.brown = brown
    }

    fileprivate var argument: String {
        let values = [
            ("background", background), ("panel", panel), ("panelAlt", panelAlt),
            ("border", border), ("muted", muted), ("text", text),
            ("textStrong", textStrong), ("contrast", contrast), ("removed", removed),
            ("orange", orange), ("modified", modified), ("added", added), ("cyan", cyan),
            ("accent", accent), ("purple", purple), ("brown", brown),
        ]
        return "{" + values.map { "\"\($0.0)\":\"\(Self.hex($0.1))\"" }.joined(separator: ",")
            + "}"
    }

    private static func hex(_ value: UInt32) -> String {
        String(format: "#%06x", value & 0x00ff_ffff)
    }
}

public struct QuinjetHostTheme: Equatable, Sendable {
    public let light: QuinjetHostPalette
    public let dark: QuinjetHostPalette

    public init(light: QuinjetHostPalette, dark: QuinjetHostPalette) {
        self.light = light
        self.dark = dark
    }

    public func palette(for appearance: QuinjetAppearance) -> QuinjetHostPalette {
        appearance == .dark ? dark : light
    }

    public var argument: String {
        "{\"light\":\(light.argument),\"dark\":\(dark.argument)}"
    }

    public static func edith(appTheme: AppTheme) -> QuinjetHostTheme {
        let accents: (UInt32, UInt32)
        switch appTheme {
        case .accent: accents = (0xd97757, 0xe08a6a)
        case .blue: accents = (0x007aff, 0x0a84ff)
        case .indigo: accents = (0x5856d6, 0x5e5ce6)
        case .teal: accents = (0x1595a3, 0x40c8e0)
        case .green: accents = (0x248a3d, 0x30d158)
        case .purple: accents = (0x8944ab, 0xbf5af2)
        case .pink: accents = (0xd30f45, 0xff375f)
        case .red: accents = (0xd70015, 0xff453a)
        case .orange: accents = (0xc93400, 0xff9f0a)
        }
        return QuinjetHostTheme(
            light: QuinjetHostPalette(
                background: 0xf7f3ec, panel: 0xfffdf8, panelAlt: 0xece5d8,
                border: 0xd6cbb8, muted: 0x5c5247, text: 0x241f1a,
                textStrong: 0x100f0d, contrast: 0x000000, removed: 0xc93c37,
                orange: 0xc46b32, modified: 0x9a6700, added: 0x2f7d42, cyan: 0x1b7c83,
                accent: accents.0, purple: 0x8250df, brown: 0x8f5e15),
            dark: QuinjetHostPalette(
                background: 0x1a1714, panel: 0x221d19, panelAlt: 0x2b2620,
                border: 0x5f5549, muted: 0xbcae9c, text: 0xf1e9dc,
                textStrong: 0xfffdf8, contrast: 0xffffff, removed: 0xff6961,
                orange: 0xf0a35e, modified: 0xe5c07b, added: 0x78c091, cyan: 0x70c5ce,
                accent: accents.1, purple: 0xc792ea, brown: 0xd7a65c))
    }
}

public struct QuinjetLaunchConfiguration: Equatable, Sendable {
    public var terminal: QuinjetTerminal
    public var theme: QuinjetTheme
    public var appearance: QuinjetAppearance
    public var hostTheme: QuinjetHostTheme?

    public init(
        terminal: QuinjetTerminal, theme: QuinjetTheme, appearance: QuinjetAppearance,
        hostTheme: QuinjetHostTheme? = nil
    ) {
        self.terminal = terminal
        self.theme = theme
        self.appearance = appearance
        self.hostTheme = hostTheme
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
        let themePreference =
            sharedDefaults.string(forKey: AppStorageKeys.Quinjet.theme)
            ?? QuinjetThemePreference.app
        let appTheme = AppTheme(
            storedName: sharedDefaults.string(forKey: AppStorageKeys.General.theme)
                ?? AppTheme.accent.rawValue)
        let theme = QuinjetThemePreference.resolve(themePreference, appTheme: appTheme)
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
            terminal: terminal, theme: theme, appearance: appearance,
            hostTheme: themePreference == QuinjetThemePreference.app
                ? .edith(appTheme: appTheme) : nil)
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
        var quinjetArguments: [String] = []
        if managedByEdith { quinjetArguments += ["--client", "edith"] }
        quinjetArguments += ["-C", worktreePath, "tui"]
        if let hostTheme = configuration.hostTheme, remote?.platform != .windows {
            quinjetArguments += ["--theme-palette", hostTheme.argument]
        } else {
            quinjetArguments += ["--theme", configuration.theme.rawValue]
        }
        quinjetArguments += ["--appearance", configuration.appearance.rawValue]
        if let remote, remote.platform == .windows {
            self.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            self.arguments =
                [
                    "-tt", "-S", remote.controlPath, "--", remote.target, "quinjet",
                ] + quinjetArguments
        } else {
            var arguments: [String] = []
            if let remote {
                arguments += [
                    "--remote", remote.target, "--ssh-control-path", remote.controlPath,
                ]
            }
            self.executableURL = executableURL
            self.arguments = arguments + quinjetArguments
        }
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

public enum QuinjetSessionOperation: String, CaseIterable, Codable, Equatable, Sendable {
    case status
    case sessions
    case create = "new"
    case focus
    case close
    case restart
    case switchWorktree = "switch"

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .status:
            descriptor("Show the selected native Quinjet session.", effect: .read)
        case .sessions:
            descriptor("List native Quinjet sessions in the running app.", effect: .read)
        case .create:
            descriptor("Create and select a native Quinjet session.", effect: .interactive)
        case .focus:
            descriptor("Select and focus a native Quinjet session.", effect: .interactive)
        case .close:
            descriptor(
                "Close a native Quinjet session.", effect: .destructive,
                requiresPreview: true)
        case .restart:
            descriptor("Restart a native Quinjet session in place.", effect: .interactive)
        case .switchWorktree:
            descriptor("Switch a native Quinjet session to another worktree.", effect: .interactive)
        }
    }

    private func descriptor(
        _ summary: String, effect: UserOperationEffect, requiresPreview: Bool = false
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "quinjet.session.\(rawValue)"), summary: summary,
            cli: ["quinjet", rawValue], effect: effect, requiresPreview: requiresPreview)
    }
}

public struct QuinjetSessionRequest: Equatable, Sendable {
    public let operation: QuinjetSessionOperation
    public let session: String?
    public let worktreePath: String?

    public init(
        operation: QuinjetSessionOperation, session: String? = nil,
        worktreePath: String? = nil
    ) {
        self.operation = operation
        self.session = session
        self.worktreePath = worktreePath
    }
}

public struct QuinjetSessionState: Codable, Equatable, Sendable {
    public let id: String
    public let index: Int
    public let title: String
    public let selected: Bool
    public let state: String
    public let terminal: String?
    public let project: String?
    public let worktreePath: String?
    public let branch: String?
    public let machine: String
    public let canClose: Bool
    public let canRestart: Bool
    public let exitMessage: String?

    public init(
        id: String, index: Int, title: String, selected: Bool, state: String,
        terminal: String?, project: String?, worktreePath: String?, branch: String?,
        machine: String, canClose: Bool, canRestart: Bool, exitMessage: String?
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.selected = selected
        self.state = state
        self.terminal = terminal
        self.project = project
        self.worktreePath = worktreePath
        self.branch = branch
        self.machine = machine
        self.canClose = canClose
        self.canRestart = canRestart
        self.exitMessage = exitMessage
    }
}

public struct QuinjetSessionResult: Codable, Equatable, Sendable {
    public let operation: QuinjetSessionOperation
    public let selectedSessionID: String?
    public let affectedSessionID: String?
    public let sessions: [QuinjetSessionState]

    public init(
        operation: QuinjetSessionOperation, selectedSessionID: String?,
        affectedSessionID: String?, sessions: [QuinjetSessionState]
    ) {
        self.operation = operation
        self.selectedSessionID = selectedSessionID
        self.affectedSessionID = affectedSessionID
        self.sessions = sessions
    }
}

public enum QuinjetSessionError: Error, Equatable, LocalizedError, Sendable {
    case pageUnavailable
    case sessionNotFound(String)
    case worktreeNotFound(String)
    case lastSession
    case reviewUnavailable(String)
    case worktreeRequired
    case operationFailed(String)

    public var code: String {
        switch self {
        case .pageUnavailable: "pageUnavailable"
        case .sessionNotFound: "sessionNotFound"
        case .worktreeNotFound: "worktreeNotFound"
        case .lastSession: "lastSession"
        case .reviewUnavailable: "reviewUnavailable"
        case .worktreeRequired: "worktreeRequired"
        case .operationFailed: "operationFailed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .pageUnavailable:
            "The Quinjet page is not open in Edith."
        case let .sessionNotFound(selector):
            "No native Quinjet session matches \(selector)."
        case let .worktreeNotFound(message):
            message
        case .lastSession:
            "The only native Quinjet session cannot be closed."
        case let .reviewUnavailable(selector):
            "Quinjet session \(selector) does not have an open review."
        case .worktreeRequired:
            "A worktree path is required for this Quinjet session operation."
        case let .operationFailed(message):
            message
        }
    }
}

public enum QuinjetSessionIPC {
    public static let requestIDKey = "requestID"
    public static let operationKey = "operation"
    public static let sessionKey = "session"
    public static let worktreePathKey = "worktreePath"
    public static let okKey = "ok"
    public static let payloadKey = "payload"
    public static let errorKey = "error"
    public static let errorCodeKey = "errorCode"
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
        let resolvedPath = remote?.resolve(path) ?? path
        let worktrees = try await worktrees(at: resolvedPath, remote: remote, using: client).filter(
            \.canOpen)
        guard let worktree = worktree(containing: resolvedPath, in: worktrees) else {
            throw QuinjetOperationError.noOpenWorktree(resolvedPath)
        }
        return QuinjetOpenSelection(
            projectName: QuinjetPath.name(worktree.path),
            worktree: worktree, worktrees: worktrees)
    }

    public static func worktree(containing path: String, in worktrees: [QuinjetWorktree])
        -> QuinjetWorktree?
    {
        if let exact = worktrees.first(where: { QuinjetPath.equals($0.path, path) }) {
            return exact
        }
        let enclosing = worktrees.filter { QuinjetPath.contains(path, in: $0.path) }
        if let deepest = enclosing.max(by: { $0.path.count < $1.path.count }) { return deepest }
        return worktrees.first(where: \.current) ?? worktrees.first
    }

    public static func terminalEnvironment() -> [String] {
        var environment = CLIToolEnvironment.sanitized()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        return environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
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
