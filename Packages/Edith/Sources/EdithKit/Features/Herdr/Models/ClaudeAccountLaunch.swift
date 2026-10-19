import Foundation

extension ClaudeAccount {
    public func launchCommand(
        command: String, arguments: [String], environment: String = "",
        platform: RemoteMachinePlatform = .darwin, configurationPath: String? = nil
    ) throws -> String {
        try validateLaunch()
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            command.utf8.count <= 16_384, !command.utf8.contains(0),
            arguments.count <= 256,
            arguments.allSatisfy({ $0.utf8.count <= 8192 && !$0.utf8.contains(0) }),
            configurationPath.map({
                !$0.isEmpty && $0.utf8.count <= 8192 && !$0.utf8.contains(0)
                    && !$0.contains(where: { $0.isNewline })
            }) ?? true,
            authentication != .browserLogin || configurationPath != nil
        else { throw ClaudeAccountError.invalidRequest }
        var assignments = try HerdrLaunchSettings.environmentAssignments(environment)
        let cleared = [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES", "ANTHROPIC_BASE_URL",
            "ANTHROPIC_PROFILE", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST",
        ]
        if authentication == .browserLogin, let configurationPath {
            assignments += [
                ("CLAUDE_CONFIG_DIR", configurationPath),
                ("CLAUDE_SECURESTORAGE_CONFIG_DIR", configurationPath),
            ]
        }
        let handoff = Self.launchCredentialVariable
        var lines: [String]
        if platform == .windows {
            lines = cleared.map { "Remove-Item Env:" + $0 + " -ErrorAction SilentlyContinue" }
            lines += assignments.map { "$env:" + $0.0 + "=" + PowerShell.literal($0.1) }
            if let variable = credentialVariable {
                lines += [
                    "$env:" + variable + "=$env:" + handoff,
                    "Remove-Item Env:" + handoff + " -ErrorAction SilentlyContinue",
                ]
            }
        } else {
            lines = ["unset " + cleared.joined(separator: " ")]
            lines += assignments.map { "export " + $0.0 + "=" + ShellQuote.quote($0.1) }
            if let variable = credentialVariable {
                lines += ["export " + variable + "=\"$" + handoff + "\"", "unset " + handoff]
            }
        }
        lines.append(
            HerdrPaneRunCommand.commandText(command, appending: arguments, platform: platform))
        let launch = lines.joined(separator: "; ")
        guard launch.utf8.count <= 65_536 else { throw ClaudeAccountError.invalidRequest }
        return launch
    }

    public static let launchCredentialVariable = "EDITH_ACCOUNT_CREDENTIAL"

    public var launchEnvironment: [String: String] {
        credentialVariable == nil ? [:] : [Self.launchCredentialVariable: credential]
    }

    private var credentialVariable: String? {
        switch authentication {
        case .oauthToken: "CLAUDE_CODE_OAUTH_TOKEN"
        case .apiKey: "ANTHROPIC_API_KEY"
        case .browserLogin: nil
        }
    }

}
