import Foundation

public struct ClaudeAccount: Codable, Equatable, Identifiable, Sendable {
    public enum Authentication: String, Codable, CaseIterable, Identifiable, Sendable {
        case oauthToken
        case apiKey
        case browserLogin

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .oauthToken: "OAuth token"
            case .apiKey: "API key"
            case .browserLogin: "Claude subscription login"
            }
        }
    }

    public var id = UUID()
    public var name: String
    public var authentication: Authentication = .oauthToken
    public var credential = ""
    public var loginData: String?
    public var limitsProfileID: UUID?

    public init(
        id: UUID = UUID(), name: String, authentication: Authentication = .oauthToken,
        credential: String = ""
    ) {
        self.id = id
        self.name = name
        self.authentication = authentication
        self.credential = credential
    }

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

    public static func currentCLIAccount(
        environment: [String: String], savedLoginData: Data? = nil
    ) throws -> ClaudeAccount {
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            return ClaudeAccount(name: "Current CLI account", credential: token)
        }
        if let key = environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return ClaudeAccount(
                name: "Current CLI account", authentication: .apiKey, credential: key)
        }
        if let savedLoginData,
            let object = try? JSONSerialization.jsonObject(with: savedLoginData) as? [String: Any],
            let login = object["claudeAiOauth"] as? [String: Any],
            let token = login["accessToken"] as? String, !token.isEmpty,
            let value = String(data: savedLoginData, encoding: .utf8)
        {
            var account = ClaudeAccount(
                name: "Current CLI account", authentication: .browserLogin, credential: token)
            account.loginData = value
            try account.validate()
            return account
        }
        throw ClaudeAccountError.rejected(
            "No current Claude credentials were found. Sign in with the CLI or add a token manually."
        )
    }

    public static func currentCLIAccount(on machine: Machine) async throws -> ClaudeAccount {
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        try await connection.connect()
        guard await connection.remotePlatform != .windows else {
            throw ClaudeAccountError.rejected(
                "CLI account import requires a POSIX shell on this machine.")
        }
        let cleanEnvironment = inheritedAuthenticationVariables.map { "-u " + $0 }.joined(
            separator: " ")
        let result = try await connection.run(
            "env " + cleanEnvironment + " \"${SHELL:-/bin/sh}\" -lic env", timeout: 15)
        guard result.succeeded else { throw HerdrCommandError.commandFailed(result.stderrText) }
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
        let saved = try await connection.run(
            "head -c 65537 " + ShellQuote.quote(folder + "/.credentials.json"), timeout: 5)
        return try currentCLIAccount(
            environment: environment, savedLoginData: saved.succeeded ? saved.stdout : nil)
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            name.utf8.count <= 128, credential.utf8.count <= 8192,
            (loginData?.utf8.count ?? 0) <= 65_536,
            !name.utf8.contains(0), !credential.utf8.contains(0)
        else { throw ClaudeAccountError.rejected("Enter a valid account name and credential.") }
    }

    public func validateLaunch() throws {
        try validate()
        guard authentication == .browserLogin || !credential.isEmpty else {
            throw ClaudeAccountError.rejected(
                "Enter a credential for this account in launch settings.")
        }
    }

    public func launchCommand(
        command: String, arguments: [String], environment: String = "",
        platform: RemoteMachinePlatform = .darwin, configurationPath: String? = nil,
        authenticationOnly: Bool = false
    ) throws -> String {
        try validateLaunch()
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeAccountError.rejected("Enter a Claude launch command in launch settings.")
        }
        let variables = try HerdrLaunchSettings.environmentAssignments(environment)
        let cleared = Self.inheritedAuthenticationVariables.filter { !$0.hasSuffix("CONFIG_DIR") }
        let credentialName =
            authentication == .apiKey ? "ANTHROPIC_API_KEY" : "CLAUDE_CODE_OAUTH_TOKEN"
        var assignments = variables
        if authentication == .browserLogin {
            if let configurationPath {
                assignments += [
                    ("CLAUDE_CONFIG_DIR", configurationPath),
                    ("CLAUDE_SECURESTORAGE_CONFIG_DIR", configurationPath),
                    ("CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "1"),
                ]
            }
        } else {
            assignments.append((credentialName, credential))
        }
        var lines: [String]
        if platform == .windows {
            lines = cleared.map { "Remove-Item Env:" + $0 + " -ErrorAction SilentlyContinue" }
            lines += assignments.map { "$env:" + $0.0 + "=" + PowerShell.literal($0.1) }
        } else {
            lines = ["unset " + cleared.joined(separator: " ")]
            lines += assignments.map { "export " + $0.0 + "=" + ShellQuote.quote($0.1) }
        }
        let launch = HerdrPaneRunCommand.commandText(
            command, appending: arguments, platform: platform)
        if authenticationOnly {
            guard authentication == .browserLogin, configurationPath != nil else {
                throw ClaudeAccountError.invalidRequest
            }
            lines.append(
                HerdrPaneRunCommand.commandText(
                    command, appending: arguments + ["auth", "login", "--claudeai"],
                    platform: platform))
        } else if authentication == .browserLogin, configurationPath != nil {
            let status = HerdrPaneRunCommand.commandText(
                command, appending: arguments + ["auth", "status", "--json"], platform: platform)
            let login = HerdrPaneRunCommand.commandText(
                command, appending: arguments + ["auth", "login", "--claudeai"], platform: platform)
            let message =
                "Subscription login is not active. Check your CLI authentication settings and try again."
            if platform == .windows {
                lines.append(
                    ClaudeSubscriptionAuthentication.powerShell(
                        status: status, login: login, launch: launch, failure: message))
            } else {
                lines.append(
                    ClaudeSubscriptionAuthentication.posix(
                        status: status, login: login, launch: launch, failure: message))
            }
        } else {
            lines.append(launch)
        }
        return lines.joined(separator: "; ")
    }

}

public struct ClaudeAccountsState: Codable, Equatable {
    public var accounts: [ClaudeAccount] = []
    public var defaultID: UUID?

    public init(accounts: [ClaudeAccount] = [], defaultID: UUID? = nil) {
        self.accounts = accounts
        self.defaultID = defaultID
    }

    public func validate() throws {
        guard accounts.count <= 64, Set(accounts.map(\.id)).count == accounts.count,
            defaultID == nil || accounts.contains(where: { $0.id == defaultID })
        else { throw ClaudeAccountError.invalidRequest }
        for account in accounts { try account.validate() }
        guard try JSONEncoder().encode(self).count <= 60_000 else {
            throw ClaudeAccountError.rejected("The saved account credentials are too large.")
        }
    }
}

public enum ClaudeAccountError: LocalizedError {
    case invalidRequest
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The account settings are invalid."
        case .rejected(let reason): reason
        }
    }
}
