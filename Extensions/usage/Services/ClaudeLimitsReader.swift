import EdithExtensionSupport
import EdithExtensionAccounts
import Foundation

public enum ClaudeLimitsReader {
    public enum Failure: LocalizedError, Equatable, Sendable {
        case missingToken
        case invalidToken
        case unauthorized
        case missingProfileScope
        case forbidden
        case unavailable
        case rateLimited(TimeInterval?)
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .missingToken:
                "Sign in with Claude Code or export a profile-scoped CLAUDE_CODE_OAUTH_TOKEN to read limits."
            case .invalidToken:
                "CLAUDE_CODE_OAUTH_TOKEN is not a valid OAuth token value."
            case .unauthorized:
                "The Claude login expired or was rejected. Sign in again with Claude Code or update CLAUDE_CODE_OAUTH_TOKEN."
            case .missingProfileScope:
                "Sign in with Claude Code to read limits. The current OAuth token lacks user:profile scope."
            case .forbidden:
                "The Claude OAuth token is not permitted to read usage limits."
            case .unavailable: "Claude did not return usage limits."
            case .rateLimited: "Claude rate limited the limits refresh."
            case .http(let code): "Claude's usage API returned HTTP \(code)."
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(
            configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    public static func fetch() async throws -> LimitsProviderSnapshot {
        guard UsageExecutionEnvironment.fixtureHome == nil else { throw Failure.missingToken }
        try Task.checkCancellation()
        UserShellEnvironment.shared.enable()
        await UserShellEnvironment.shared.refreshIfEnabled()
        let environment = UserShellEnvironment.userEnvironment()
        let token = try await resolveUsageToken(
            savedLogin: { UsageSavedLogin.token(environment: environment) },
            shellToken: { try await resolveToken() })
        return try await fetch(token: token) { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
            return (data, response)
        }
    }

    public static func fetch(account: ClaudeAccount, directory: URL) async throws
        -> LimitsProviderSnapshot
    {
        guard UsageExecutionEnvironment.fixtureHome == nil else { throw Failure.missingToken }
        try Task.checkCancellation()
        return try await fetchAccount(
            account, directory: directory,
            resolveToken: { try await resolveAccountToken(account, directory: directory) },
            send: { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
                return (data, response)
            })
    }

    static func accountIsCurrent(_ account: ClaudeAccount, directory: URL) async throws -> Bool {
        let storage = ClaudeAccountStorage(directory: directory)
        let state = try await storage.load()
        return state.accounts.contains(account)
    }

    static func fetchAccount(
        _ account: ClaudeAccount, directory: URL,
        isCurrent: @Sendable (ClaudeAccount, URL) async throws -> Bool = accountIsCurrent,
        resolveToken: () async throws -> String,
        send: (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> LimitsProviderSnapshot {
        try Task.checkCancellation()
        guard try await isCurrent(account, directory) else { throw CancellationError() }
        let token = try await resolveToken()
        try Task.checkCancellation()
        guard try await isCurrent(account, directory) else { throw CancellationError() }
        let result: LimitsProviderSnapshot
        do {
            result = try await fetch(token: token, send: send)
        } catch {
            try Task.checkCancellation()
            guard try await isCurrent(account, directory) else { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard try await isCurrent(account, directory) else { throw CancellationError() }
        return result
    }

    static func accountToken(
        _ account: ClaudeAccount, directory: URL,
        savedLogin: (ClaudeAccount, URL) -> String? = { account, directory in
            ClaudeSavedLogin.scopedToken(
                account: account, directory: directory,
                readScopedSecret: { UsageSavedLogin.scopedCredentials(directory: $0) })
        }
    ) throws -> String {
        try Task.checkCancellation()
        try account.validate()
        guard !account.isLoggedOut else { throw Failure.missingToken }
        switch account.authentication {
        case .apiKey:
            throw ClaudeAccountError.rejected(
                "Subscription limits are unavailable for API-key accounts.")
        case .oauthToken:
            guard account.limitsProfileID == nil else { throw Failure.missingToken }
            return try validatedToken(account.credential)
        case .browserLogin:
            guard let token = savedLogin(account, directory) else {
                throw ClaudeAccountError.rejected(
                    "Launch a session with this account and complete Claude's login to show its limits."
                )
            }
            return try validatedToken(token)
        }
    }

    static func resolveAccountToken(
        _ account: ClaudeAccount, directory: URL,
        isCurrent: @Sendable (ClaudeAccount, URL) async throws -> Bool = accountIsCurrent,
        savedLogin: (ClaudeAccount, URL) -> String? = { account, directory in
            ClaudeSavedLogin.scopedToken(
                account: account, directory: directory,
                readScopedSecret: { UsageSavedLogin.scopedCredentials(directory: $0) })
        },
        remoteLogin: @Sendable (ClaudeAccount) async throws -> String? = {
            try await ClaudeAccountRemoteLogin.token(account: $0)
        },
        linkedLogin: @Sendable (ClaudeAccount, URL) async throws -> String = {
            try await ClaudeLimitsLogin.token(account: $0, directory: $1)
        }
    ) async throws -> String {
        try Task.checkCancellation()
        try account.validate()
        guard !account.isLoggedOut else { throw Failure.missingToken }
        guard try await isCurrent(account, directory) else { throw CancellationError() }
        try Task.checkCancellation()
        let token: String
        if account.limitsProfileID != nil {
            token = try validatedToken(await linkedLogin(account, directory))
        } else if account.authentication == .browserLogin, let machineID = account.remoteMachineID {
            guard UUID(uuidString: machineID) != nil else {
                throw ClaudeAccountError.invalidRequest
            }
            if let local = savedLogin(account, directory) {
                token = try validatedToken(local)
            } else {
                try Task.checkCancellation()
                guard try await isCurrent(account, directory) else { throw CancellationError() }
                guard let remote = try await remoteLogin(account) else {
                    throw Failure.missingToken
                }
                token = try validatedToken(remote)
            }
        } else {
            token = try accountToken(account, directory: directory, savedLogin: savedLogin)
        }
        try Task.checkCancellation()
        guard try await isCurrent(account, directory) else { throw CancellationError() }
        return token
    }

    static func resolveUsageToken(
        savedLogin: () -> String?, shellToken: () async throws -> String
    ) async throws -> String {
        if let token = savedLogin() { return try validatedToken(token) }
        return try await shellToken()
    }

    static func resolveToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shell: () async -> [String: String]? = {
            UserShellEnvironment.shared.enable()
            await UserShellEnvironment.shared.refreshIfEnabled()
            return UserShellEnvironment.shared.current()
        }
    ) async throws -> String {
        let value: String?
        if let inherited = environment["CLAUDE_CODE_OAUTH_TOKEN"] {
            value = inherited
        } else {
            value = await shell()?["CLAUDE_CODE_OAUTH_TOKEN"]
        }
        guard let value else { throw Failure.missingToken }
        return try validatedToken(value)
    }

    static func validatedToken(_ value: String) throws -> String {
        guard !value.isEmpty else { throw Failure.missingToken }
        guard value.utf8.count <= 8192,
            value.unicodeScalars.allSatisfy({ 0x21...0x7E ~= $0.value })
        else { throw Failure.invalidToken }
        return value
    }

    static func fetch(
        token: String,
        send: (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> LimitsProviderSnapshot {
        let endpoint = "https://api.anthropic.com/api/oauth/usage"
        var request = URLRequest(url: URL(string: endpoint + "?cedar_ember=1")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-cli/2.1.0 (external, cli)", forHTTPHeaderField: "User-Agent")
        var (data, response) = try await send(request)
        if response.statusCode == 400
            || (response.statusCode == 403 && !requiresProfileScope(data))
        {
            try Task.checkCancellation()
            request.url = URL(string: endpoint)!
            request.setValue("claude-cli/2.1.0", forHTTPHeaderField: "User-Agent")
            (data, response) = try await send(request)
        }
        switch response.statusCode {
        case 200: return try limits(json: data)
        case 401: throw Failure.unauthorized
        case 403:
            if requiresProfileScope(data) { throw Failure.missingProfileScope }
            throw Failure.forbidden
        case 429:
            throw Failure.rateLimited(
                response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default: throw Failure.http(response.statusCode)
        }
    }

    private static func requiresProfileScope(_ data: Data) -> Bool {
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = body?["error"] as? [String: Any]
        return (error?["message"] as? String)?.contains("user:profile") == true
    }

    static func limits(json data: Data) throws -> LimitsProviderSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unavailable
        }
        func window(_ value: Any?, field: String = "utilization") -> LimitWindow? {
            guard let value = value as? [String: Any], let percent = value[field] as? Double,
                percent.isFinite, percent >= 0
            else { return nil }
            return LimitWindow(
                percent: percent, resetsAt: EdithDate.parseISO(value["resets_at"] as? String))
        }
        let scoped = (object["limits"] as? [[String: Any]])?.first { limit in
            let scope = limit["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = model?["display_name"] as? String
            return limit["kind"] as? String == "weekly_scoped"
                && name?.lowercased().hasPrefix("fable") == true
        }
        let session = window(object["five_hour"])
        let week = window(object["seven_day"])
        let fable = window(object["seven_day_fable"]) ?? window(scoped, field: "percent")
        guard session != nil || week != nil || fable != nil else { throw Failure.unavailable }
        return LimitsProviderSnapshot(provider: .claude, session: session, week: week, fable: fable)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
