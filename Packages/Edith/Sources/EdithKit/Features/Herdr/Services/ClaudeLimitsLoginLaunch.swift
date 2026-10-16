import Foundation

public struct ClaudeLimitsLoginLaunch: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String]
    public let currentDirectory: String

    public static func prepare(
        account: ClaudeAccount, profileID: UUID, folder: URL, command: String,
        sharedEnvironment: String, inheritedEnvironment: [String: String]
    ) throws -> ClaudeLimitsLoginLaunch {
        try account.validateLaunch()
        guard account.authentication == .oauthToken, !account.isLoggedOut,
            profileID != account.id, profileID != account.limitsProfileID,
            folder.isFileURL, folder.path.hasPrefix("/"),
            folder.lastPathComponent == profileID.uuidString
        else { throw ClaudeAccountError.invalidRequest }
        let shared = try HerdrLaunchSettings.environmentAssignments(sharedEnvironment)
        guard !shared.contains(where: { ["HISTFILE", "SAVEHIST"].contains($0.0.uppercased()) })
        else { throw ClaudeAccountError.invalidRequest }
        let profile = ClaudeAccount(
            id: profileID, name: "Subscription login", authentication: .browserLogin)
        let script = try profile.launchCommand(
            command: command, arguments: ["auth", "login"], environment: sharedEnvironment,
            configurationPath: folder.path)
        let reserved: Set<String> = [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES", "ANTHROPIC_BASE_URL",
            "ANTHROPIC_PROFILE", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST",
            "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "HISTFILE", "SAVEHIST",
        ]
        var environment = inheritedEnvironment.filter { !reserved.contains($0.key.uppercased()) }
        environment["HISTFILE"] = "/dev/null"
        environment["SAVEHIST"] = "0"
        return ClaudeLimitsLoginLaunch(
            executable: "/bin/zsh",
            arguments: ["-l", "-i", "-c", "unset HISTFILE; SAVEHIST=0; " + script],
            environment: environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value },
            currentDirectory: folder.path)
    }
}
