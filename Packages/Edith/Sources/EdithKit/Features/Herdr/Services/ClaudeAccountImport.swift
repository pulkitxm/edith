import EdithCore
import Foundation

extension ClaudeAccount {
    private static let inheritedAuthenticationVariables = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES", "ANTHROPIC_BASE_URL",
        "ANTHROPIC_PROFILE", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR",
    ]

    public static func currentCLIEnvironment(
        shell: URL = UserShellEnvironment.loginShell(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> [String: String] {
        var environment = base
        for name in inheritedAuthenticationVariables { environment.removeValue(forKey: name) }
        guard
            let captured = await UserShellEnvironment.captureLoginEnvironment(
                shell: shell, home: home, base: environment)
        else {
            throw ClaudeAccountError.rejected(
                "Could not read the current CLI login from a fresh shell. Try again.")
        }
        return captured
    }

    public static func currentCLIAccount(on machine: Machine) async throws -> ClaudeAccount {
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        try await connection.connect()
        guard let platform = await connection.remotePlatform, platform != .windows else {
            throw ClaudeAccountError.rejected(
                "CLI account import requires a POSIX shell on this machine.")
        }
        let cleanEnvironment = inheritedAuthenticationVariables.map { "-u " + $0 }.joined(
            separator: " ")
        let result = try await connection.run(
            "env " + cleanEnvironment + " \"${SHELL:-/bin/sh}\" -lic env", timeout: 15)
        try Task.checkCancellation()
        guard result.succeeded, result.stdout.count <= 1_048_576 else {
            throw ClaudeAccountError.rejected("The selected machine could not provide a CLI login.")
        }
        let environment = Dictionary(
            result.stdoutText.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(
                    separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            }, uniquingKeysWith: { _, last in last })
        if environment["CLAUDE_CODE_OAUTH_TOKEN"]?.isEmpty == false
            || environment["ANTHROPIC_API_KEY"]?.isEmpty == false
        {
            return try currentCLIAccount(environment: environment)
        }
        let folder =
            environment["CLAUDE_CONFIG_DIR"] ?? (environment["HOME", default: ""] + "/.claude")
        guard folder.hasPrefix("/"), folder.utf8.count <= 8192, !folder.utf8.contains(0) else {
            throw ClaudeAccountError.invalidRequest
        }
        let credentialPath = folder + "/.credentials.json"
        let guardSource =
            "directory=" + ShellQuote.quote(folder)
            + "; canonical=$(cd -P \"$directory\" && pwd -P) || exit 1; test \"$canonical\" = \"$directory\" && test -O \"$directory\" || exit 1; "
            + (try ClaudeAccountImport.remoteCredentialValidation(
                path: credentialPath, platform: platform))
        let saved = try await connection.run(
            guardSource + "; head -c 65537 " + ShellQuote.quote(credentialPath), timeout: 5)
        try Task.checkCancellation()
        guard saved.stdout.count <= 65_536 else { throw ClaudeAccountError.invalidRequest }
        return try currentCLIAccount(
            environment: environment, savedLoginData: saved.succeeded ? saved.stdout : nil)
    }

}

public enum ClaudeAccountImport {
    static func remoteProfileExpression(
        accountID: UUID, identifier: String = AppBuildIdentity.application
    ) throws -> String {
        guard
            identifier == "com.pulkit.edith"
                || identifier.range(
                    of: "^com\\.pulkit\\.edith\\.(dev|tests)\\.[A-Za-z0-9_-]{1,160}$",
                    options: .regularExpression) != nil
        else { throw ClaudeAccountError.invalidRequest }
        return "\"$HOME\"/"
            + ShellQuote.quote(
                ".local/share/edith/" + identifier + "/accounts/" + accountID.uuidString)
    }

    static func remoteScopeValidation(
        accountID: UUID, identifier: String = AppBuildIdentity.application
    ) throws -> String {
        _ = try remoteProfileExpression(accountID: accountID, identifier: identifier)
        let relatives = [
            ".local", ".local/share", ".local/share/edith",
            ".local/share/edith/" + identifier,
            ".local/share/edith/" + identifier + "/accounts",
            ".local/share/edith/" + identifier + "/accounts/" + accountID.uuidString,
        ].map(ShellQuote.quote).joined(separator: " ")
        return
            "case \"$HOME\" in /*) ;; *) exit 1;; esac; test -d \"$HOME\" && test ! -L \"$HOME\" && test -O \"$HOME\" || exit 1; for relative in "
            + relatives
            + "; do candidate=\"$HOME/$relative\"; if [ -L \"$candidate\" ] || { [ -e \"$candidate\" ] && { [ ! -d \"$candidate\" ] || [ ! -O \"$candidate\" ]; }; }; then exit 1; fi; done"
    }

    static func remoteCredentialValidation(path: String, platform: RemoteMachinePlatform) throws
        -> String
    {
        guard path.hasPrefix("/"), path.utf8.count <= 8192, !path.utf8.contains(0) else {
            throw ClaudeAccountError.invalidRequest
        }
        let file = ShellQuote.quote(path)
        let metadata: String
        switch platform {
        case .darwin: metadata = "stat -f '%Lp %u %l %z' " + file
        case .linux: metadata = "stat -c '%a %u %h %s' -- " + file
        case .windows: throw ClaudeAccountError.invalidRequest
        }
        return "test ! -L " + file + " || exit 1; if [ -e " + file + " ]; then test -f " + file
            + " && test -O " + file + " || exit 1; metadata=$(" + metadata
            + ") || exit 1; set -- $metadata; test \"$#\" = 4 && test \"$1\" = 600 && test \"$2\" = \"$(id -u)\" && test \"$3\" = 1 || exit 1; case \"$4\" in ''|*[!0-9]*) exit 1;; esac; test \"$4\" -le 65536 || exit 1; fi"
    }

    public static func removeRemoteProfile(accountID: UUID, machineID: String) async throws {
        guard
            let machine = MachineRegistry.machines().first(where: { $0.id.uuidString == machineID })
        else {
            throw ClaudeAccountError.rejected(
                "Enable the saved account's machine to remove its remote login.")
        }
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        try await connection.connect()
        guard await connection.remotePlatform != .windows else {
            throw ClaudeAccountError.invalidRequest
        }
        let folder = try remoteProfileExpression(accountID: accountID)
        let result = try await connection.run(
            try remoteScopeValidation(accountID: accountID) + "; folder=" + folder
                + "; if [ -e \"$folder\" ]; then rm -rf -- \"$folder\"; fi",
            timeout: 15)
        guard result.succeeded else {
            throw ClaudeAccountError.rejected(
                "The account's remote login could not be removed. Try again.")
        }
    }
}
