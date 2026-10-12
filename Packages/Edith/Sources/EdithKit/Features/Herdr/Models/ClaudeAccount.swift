import Foundation

public struct ClaudeAccount: Codable, Equatable, Identifiable, Sendable {
    public enum Authentication: String, Codable, CaseIterable, Identifiable {
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

    public init(
        id: UUID = UUID(), name: String, authentication: Authentication = .oauthToken,
        credential: String = ""
    ) {
        self.id = id
        self.name = name
        self.authentication = authentication
        self.credential = credential
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            name.utf8.count <= 128, credential.utf8.count <= 8192,
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

    public func launcher(command: String, arguments: [String], directory: URL) throws -> URL {
        try validateLaunch()
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeAccountError.rejected("Enter a Claude launch command in launch settings.")
        }
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var lines = [
            "#!/bin/sh",
            "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_PROFILE CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY",
            "export CLAUDE_CONFIG_DIR=" + ShellQuote.quote(folder.path),
        ]
        switch authentication {
        case .oauthToken:
            lines.append("export CLAUDE_CODE_OAUTH_TOKEN=" + ShellQuote.quote(credential))
        case .apiKey:
            lines.append("export ANTHROPIC_API_KEY=" + ShellQuote.quote(credential))
        case .browserLogin: break
        }
        lines.append("/bin/rm -f -- \"$0\"")
        lines.append("exec " + HerdrPaneRunCommand.commandText(command, appending: arguments))
        let file = folder.appendingPathComponent("launch-\(UUID().uuidString).sh")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
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
