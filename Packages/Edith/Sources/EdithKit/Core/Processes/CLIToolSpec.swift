import Foundation

public enum CLIToolRequirement: Equatable, Sendable {
    case always
    case whenPreferenceEnabled(key: String, defaultValue: Bool)

    @MainActor public func isActive(defaults: UserDefaults = SharedDefaults.store) -> Bool {
        switch self {
        case .always:
            return true
        case let .whenPreferenceEnabled(key, defaultValue):
            guard defaults.object(forKey: key) != nil else { return defaultValue }
            return defaults.bool(forKey: key)
        }
    }
}

public enum CLIToolPresenceStrategy: Equatable, Sendable {
    case executable(name: String, versionArguments: [String])
}

public enum CLIToolInstallStrategy: Equatable, Sendable {
    case manual(instruction: String)
    case standaloneBinary(url: URL, destinationName: String, instruction: String)
    case homebrew(arguments: [String], instruction: String)
    case packageManagers(
        homebrewArguments: [String], npmPackage: String, instruction: String
    )

    public var instruction: String {
        switch self {
        case let .manual(instruction):
            return instruction
        case let .standaloneBinary(_, _, instruction):
            return instruction
        case let .homebrew(_, instruction):
            return instruction
        case let .packageManagers(_, _, instruction):
            return instruction
        }
    }
}

public struct CLIToolSpec: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let why: String
    public let requirement: CLIToolRequirement
    public let presenceStrategy: CLIToolPresenceStrategy
    public let installStrategy: CLIToolInstallStrategy
    public let versionProbeTimeout: TimeInterval

    public init(
        id: String, displayName: String, why: String,
        requirement: CLIToolRequirement = .always,
        presenceStrategy: CLIToolPresenceStrategy,
        installStrategy: CLIToolInstallStrategy,
        versionProbeTimeout: TimeInterval = 5
    ) {
        self.id = id
        self.displayName = displayName
        self.why = why
        self.requirement = requirement
        self.presenceStrategy = presenceStrategy
        self.installStrategy = installStrategy
        self.versionProbeTimeout = versionProbeTimeout
    }

    public static let youtubeDownloader = CLIToolSpec(
        id: "yt-dlp", displayName: "yt-dlp",
        why: "Downloads YouTube audio into your Music library.",
        presenceStrategy: .executable(name: "yt-dlp", versionArguments: ["--version"]),
        installStrategy: .standaloneBinary(
            url: URL(
                string:
                    "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
            )!,
            destinationName: "yt-dlp",
            instruction:
                "Download yt-dlp_macos from the official yt-dlp release and place it in a folder on PATH."
        ),
        versionProbeTimeout: 30)

    public static let ffmpeg = CLIToolSpec(
        id: "ffmpeg", displayName: "FFmpeg",
        why: "Converts downloaded audio and powers Studio's video and audio tools.",
        presenceStrategy: .executable(name: "ffmpeg", versionArguments: ["-version"]),
        installStrategy: .homebrew(
            arguments: ["install", "ffmpeg"],
            instruction: "Install with `brew install ffmpeg`."))

    public static let qpdf = CLIToolSpec(
        id: "qpdf", displayName: "qpdf",
        why: "Lets Studio decompress, linearize and deeply repair PDFs.",
        presenceStrategy: .executable(name: "qpdf", versionArguments: ["--version"]),
        installStrategy: .homebrew(
            arguments: ["install", "qpdf"],
            instruction: "Install with `brew install qpdf`."))

    public static let deno = CLIToolSpec(
        id: "deno", displayName: "Deno",
        why: "Enables YouTube downloads with yt-dlp.",
        presenceStrategy: .executable(name: "deno", versionArguments: ["--version"]),
        installStrategy: .homebrew(
            arguments: ["install", "deno"],
            instruction: "Install with `brew install deno`."))

    public static let claudeCode = CLIToolSpec(
        id: "claude", displayName: "Claude Code",
        why: "Includes Claude Code cloud sessions in Agent Usage.",
        presenceStrategy: .executable(name: "claude", versionArguments: ["--version"]),
        installStrategy: .packageManagers(
            homebrewArguments: ["install", "--cask", "claude-code"],
            npmPackage: "@anthropic-ai/claude-code",
            instruction:
                "Install with `brew install --cask claude-code` or `npm install -g @anthropic-ai/claude-code`."
        ))

    public static let codex = CLIToolSpec(
        id: "codex", displayName: "Codex",
        why: "Reads Codex session and weekly limits when that provider is enabled.",
        requirement: .whenPreferenceEnabled(
            key: AppStorageKeys.Limits.codexEnabled, defaultValue: true),
        presenceStrategy: .executable(name: "codex", versionArguments: ["--version"]),
        installStrategy: .packageManagers(
            homebrewArguments: ["install", "--cask", "codex"],
            npmPackage: "@openai/codex",
            instruction:
                "Install with `brew install --cask codex` or `npm install -g @openai/codex`."
        ))

    public static let quinjet = CLIToolSpec(
        id: "quinjet", displayName: "Quinjet",
        why: "Powers local pull request review and live workspace changes.",
        presenceStrategy: .executable(name: "quinjet", versionArguments: ["--version"]),
        installStrategy: .homebrew(
            arguments: ["install", "pulkitxm/tap/quinjet"],
            instruction: "Install with `brew install pulkitxm/tap/quinjet`."))

    public static let homebrew = CLIToolSpec(
        id: "homebrew", displayName: "Homebrew",
        why: "Provides the formula and cask catalog managed by this extension.",
        presenceStrategy: .executable(name: "brew", versionArguments: ["--version"]),
        installStrategy: .manual(
            instruction: "Install Homebrew from https://brew.sh, then check again."))
}

public enum CLIToolEnvironment {
    public static func sanitized(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        shellEnvironment: [String: String]? = UserShellEnvironment.shared.current(),
        fileManager: FileManager = .default
    ) -> [String: String] {
        var environment = processEnvironment
        for (key, value) in shellEnvironment ?? [:]
        where UserShellEnvironment.imports(key) && processEnvironment[key] == nil {
            environment[key] = value
        }
        environment.removeValue(forKey: "NO_COLOR")
        let directories = commonDirectories(
            processEnvironment: processEnvironment, fileManager: fileManager)
        let shellPath = shellEnvironment?["PATH"]?.split(separator: ":").map(String.init) ?? []
        let existing = processEnvironment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = uniqueAllowedDirectories(
            directories.prefix(1) + shellPath + directories.dropFirst() + existing
        ).joined(separator: ":")
        return environment
    }

    public static func executable(
        named name: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        shellEnvironment: [String: String]? = UserShellEnvironment.shared.current(),
        fileManager: FileManager = .default
    ) -> URL? {
        let environment = sanitized(
            processEnvironment: processEnvironment, shellEnvironment: shellEnvironment,
            fileManager: fileManager)
        for directory in environment["PATH"]?.split(separator: ":").map(String.init) ?? [] {
            guard RestoredPathValidation.verdict(for: directory) == .keep else { continue }
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func commonDirectories(
        processEnvironment: [String: String], fileManager: FileManager
    ) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser
        var directories = [
            AppData.supportDir.appendingPathComponent("bin").path,
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".cargo/bin").path,
            home.appendingPathComponent(".nvm/current/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let nvmRoot = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot, includingPropertiesForKeys: nil)
        {
            directories.insert(
                contentsOf: versions.sorted {
                    nodeVersionOrder($0.lastPathComponent, $1.lastPathComponent)
                }.map { $0.appendingPathComponent("bin").path }, at: 3)
        }
        if let configuredHome = processEnvironment["HOME"], !configuredHome.isEmpty {
            directories.insert(
                URL(fileURLWithPath: configuredHome).appendingPathComponent(".local/bin").path,
                at: 1)
        }
        return directories
    }

    static func nodeVersionOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        guard left != right else { return lhs > rhs }
        return right.lexicographicallyPrecedes(left)
    }

    private static func versionComponents(_ name: String) -> [Int] {
        name.drop { !$0.isNumber }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    private static func uniqueAllowedDirectories(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        return directories.compactMap { directory in
            let standardized = URL(fileURLWithPath: directory).standardizedFileURL.path
            guard RestoredPathValidation.verdict(for: standardized) == .keep,
                seen.insert(standardized).inserted
            else { return nil }
            return standardized
        }
    }
}

extension Notification.Name {
    public static let cliToolProvisioned = Notification.Name("cliToolProvisioned")
}
