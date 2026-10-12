import EdithExtensionAccounts
import Foundation

extension ClaudeAccount {
    func launcher(command: String, arguments: [String], directory: URL) async throws -> URL {
        try validateLaunch()
        let storage = ClaudeAccountStorage(directory: directory)
        return try await storage.writeLauncher(account: self) { profile, launcher in
            try self.launchScript(
                command: command, arguments: arguments,
                configurationPath: profile.path, launcherPath: launcher.path)
        }
    }

    func launchScript(
        command: String, arguments: [String], configurationPath: String, launcherPath: String
    ) throws -> Data {
        try validateLaunch()
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            command.utf8.count <= 16_384, !command.utf8.contains(0),
            arguments.count <= 256,
            arguments.allSatisfy({ $0.utf8.count <= 8192 && !$0.utf8.contains(0) })
        else { throw ClaudeAccountError.invalidRequest }
        let source = ". " + ShellQuote.quote(launcherPath) + " --account-environment"
        var lines = [
            "#!/bin/sh",
            "if [ \"${1-}\" != --account-environment ]; then",
            "  exec \"${SHELL:-/bin/sh}\" -lic " + ShellQuote.quote(source),
            "fi",
            "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_REFRESH_TOKEN CLAUDE_CODE_OAUTH_SCOPES ANTHROPIC_BASE_URL ANTHROPIC_PROFILE CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY",
            "export CLAUDE_CONFIG_DIR=" + ShellQuote.quote(configurationPath),
            "export CLAUDE_SECURESTORAGE_CONFIG_DIR=" + ShellQuote.quote(configurationPath),
        ]
        switch authentication {
        case .oauthToken:
            lines.append("export CLAUDE_CODE_OAUTH_TOKEN=" + ShellQuote.quote(credential))
        case .apiKey: lines.append("export ANTHROPIC_API_KEY=" + ShellQuote.quote(credential))
        case .browserLogin: break
        }
        lines.append("/bin/rm -f -- " + ShellQuote.quote(launcherPath))
        lines.append(
            "eval "
                + ShellQuote.quote(HerdrPaneRunCommand.commandText(command, appending: arguments)))
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
