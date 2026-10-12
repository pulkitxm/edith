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
    public var remoteMachineID: String?
    public var isLoggedOut = false

    public init(
        id: UUID = UUID(), name: String, authentication: Authentication = .oauthToken,
        credential: String = ""
    ) {
        self.id = id
        self.name = name
        self.authentication = authentication
        self.credential = credential
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

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            name.utf8.count <= 128, credential.utf8.count <= 8192,
            (loginData?.utf8.count ?? 0) <= 65_536,
            !name.utf8.contains(0), !credential.utf8.contains(0),
            remoteMachineID.map({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) })
                ?? true
        else { throw ClaudeAccountError.rejected("Enter a valid account name and credential.") }
    }

    public func validateLaunch() throws {
        try validate()
        guard authentication == .browserLogin || !credential.isEmpty else {
            throw ClaudeAccountError.rejected(
                "Enter a credential for this account in launch settings.")
        }
    }

}

public struct ClaudeAccountsState: Codable, Equatable, Sendable {
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

public enum ClaudeAccountError: LocalizedError, Sendable {
    case invalidRequest
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The account settings are invalid."
        case .rejected(let reason): reason
        }
    }
}
