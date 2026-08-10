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
    case standaloneBinary(url: URL, destinationName: String, instruction: String)
    case packageManagers(
        homebrewArguments: [String], npmPackage: String, instruction: String
    )

    public var instruction: String {
        switch self {
        case let .standaloneBinary(_, _, instruction):
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

    public init(
        id: String, displayName: String, why: String,
        requirement: CLIToolRequirement = .always,
        presenceStrategy: CLIToolPresenceStrategy,
        installStrategy: CLIToolInstallStrategy
    ) {
        self.id = id
        self.displayName = displayName
        self.why = why
        self.requirement = requirement
        self.presenceStrategy = presenceStrategy
        self.installStrategy = installStrategy
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
        ))

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
}

public enum CLIToolEnvironment {
    public static func sanitized(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String: String] {
        var environment = processEnvironment
        let directories = commonDirectories(
            processEnvironment: processEnvironment, fileManager: fileManager)
        let existing = processEnvironment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = uniqueAllowedDirectories(directories + existing).joined(
            separator: ":")
        return environment
    }

    public static func executable(
        named name: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let environment = sanitized(
            processEnvironment: processEnvironment, fileManager: fileManager)
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
            home.appendingPathComponent(".nvm/current/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let nvmRoot = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot, includingPropertiesForKeys: nil)
        {
            directories.insert(
                contentsOf: versions.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .reversed().map { $0.appendingPathComponent("bin").path }, at: 3)
        }
        if let configuredHome = processEnvironment["HOME"], !configuredHome.isEmpty {
            directories.insert(
                URL(fileURLWithPath: configuredHome).appendingPathComponent(".local/bin").path,
                at: 1)
        }
        return directories
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
