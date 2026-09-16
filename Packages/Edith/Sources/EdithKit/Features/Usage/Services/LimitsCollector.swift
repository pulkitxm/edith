import Darwin
import Foundation
import os

public enum ClaudeLimitsFetchError: Error, Equatable {
    case unauthorized
    case permissionDenied
    case rateLimited(after: TimeInterval?)
    case http(Int)
}

public struct LimitsProviderSnapshot: Codable, Equatable, Sendable {
    public let provider: LimitProvider
    public let session: LimitWindow?
    public let week: LimitWindow?
    public let fable: LimitWindow?
    public let error: String?

    public init(
        provider: LimitProvider, session: LimitWindow?, week: LimitWindow?,
        fable: LimitWindow? = nil, error: String? = nil
    ) {
        self.provider = provider
        self.session = session
        self.week = week
        self.fable = fable
        self.error = error
    }
}

public struct LimitsTopicSnapshot: Codable, Equatable, Sendable {
    public let refreshedAt: Date
    public let providers: [LimitsProviderSnapshot]
    public let failure: String?

    public init(refreshedAt: Date, providers: [LimitsProviderSnapshot], failure: String?) {
        self.refreshedAt = refreshedAt
        self.providers = providers
        self.failure = failure
    }
}

public enum LimitsCollector {
    private static let logger = Logger(subsystem: "com.pulkit.edith", category: "limits")

    public static func enabledProviders(defaults: UserDefaults = SharedDefaults.store)
        -> [LimitProvider]
    {
        let claude =
            defaults.object(forKey: AppStorageKeys.Limits.claudeEnabled) as? Bool ?? true
        let codex = defaults.object(forKey: AppStorageKeys.Limits.codexEnabled) as? Bool ?? true
        return UsageLimitProviders.enabled(claude: claude, codex: codex)
    }

    public static func providerEnabled(
        _ provider: LimitProvider, defaults: UserDefaults = SharedDefaults.store
    ) -> Bool {
        let key =
            provider == .claude
            ? AppStorageKeys.Limits.claudeEnabled : AppStorageKeys.Limits.codexEnabled
        return defaults.object(forKey: key) as? Bool ?? true
    }

    public static func refresh(
        force: Bool = false, defaults: UserDefaults = SharedDefaults.store,
        credentialSession: ClaudeCredentialSession = ClaudeCredentialSession(),
        refreshSession: LimitsRefreshSession = .shared,
        announce: @Sendable (Notification.Name) -> Void = { IPC.post($0) }
    ) async -> LimitsTopicSnapshot {
        await collect(
            providers: enabledProviders(defaults: defaults), force: force,
            refreshSession: refreshSession, announce: announce
        ) { provider in
            switch provider {
            case .claude:
                var retryNotBefore: Date?
                let snapshot = await fetchClaude(
                    credentialSession: credentialSession, retryNotBefore: &retryNotBefore)
                return (snapshot, retryNotBefore)
            case .codex:
                return (await fetchCodex(), nil)
            }
        }
    }

    static func collect(
        providers: [LimitProvider], force: Bool = false,
        refreshSession: LimitsRefreshSession, now: Date = Date(),
        announce: @Sendable (Notification.Name) -> Void,
        fetch: (LimitProvider) async -> (LimitsProviderSnapshot, Date?)
    ) async -> LimitsTopicSnapshot {
        let paused: [LimitsProviderSnapshot]
        switch await refreshSession.begin(force: force, providers: providers, now: now) {
        case .cached(let snapshot): return snapshot
        case .collect(let providers): paused = providers
        }
        var snapshots: [LimitsProviderSnapshot] = []
        var deadlines: [LimitProvider: Date] = [:]
        for provider in providers {
            if let cached = paused.first(where: { $0.provider == provider }) {
                snapshots.append(cached)
                if let deadline = await refreshSession.retryDeadline(for: provider) {
                    deadlines[provider] = deadline
                }
            } else {
                let (snapshot, deadline) = await fetch(provider)
                snapshots.append(snapshot)
                deadlines[provider] = deadline
            }
        }
        let snapshot = LimitsTopicSnapshot(
            refreshedAt: now, providers: snapshots, failure: snapshots.compactMap(\.error).first)
        await refreshSession.finish(snapshot, retryNotBefore: deadlines)
        announce(IPC.Name.limitsUpdated)
        return snapshot
    }

    private static func fetchClaude(
        credentialSession: ClaudeCredentialSession,
        retryNotBefore: inout Date?
    ) async -> LimitsProviderSnapshot {
        var credential: ClaudeOAuthCredential
        switch await credentialSession.current() {
        case .credential(let resolved):
            credential = resolved
        case .failure(let failure):
            return LimitsProviderSnapshot(
                provider: .claude, session: nil, week: nil, fable: nil,
                error: credentialFailureMessage(failure))
        case .cancelled:
            return LimitsProviderSnapshot(provider: .claude, session: nil, week: nil)
        }
        do {
            if credential.shouldRefresh(at: Date()) {
                credential = try await refreshClaudeCredential(
                    credential, session: credentialSession)
            }
            let usage = try await fetchUsage(token: credential.accessToken)
            try persistHistory(
                provider: .claude, session: usage.session, week: usage.week, fable: usage.fable)
            return LimitsProviderSnapshot(
                provider: .claude, session: usage.session, week: usage.week, fable: usage.fable)
        } catch ClaudeLimitsFetchError.unauthorized {
            switch await credentialSession.reload(rejectingAccessToken: credential.accessToken) {
            case .credential(let latest):
                do {
                    let fresh: ClaudeOAuthCredential
                    if latest.source == .shell {
                        fresh = latest
                    } else if latest.accessToken != credential.accessToken,
                        !latest.shouldRefresh(at: Date())
                    {
                        fresh = latest
                    } else {
                        fresh = try await refreshClaudeCredential(
                            latest, session: credentialSession)
                    }
                    let usage = try await fetchUsage(token: fresh.accessToken)
                    try persistHistory(
                        provider: .claude, session: usage.session, week: usage.week,
                        fable: usage.fable)
                    return LimitsProviderSnapshot(
                        provider: .claude, session: usage.session, week: usage.week,
                        fable: usage.fable)
                } catch {
                    return claudeFailure(error, retryNotBefore: &retryNotBefore)
                }
            case .failure(let failure):
                return LimitsProviderSnapshot(
                    provider: .claude, session: nil, week: nil, fable: nil,
                    error: credentialFailureMessage(failure))
            case .cancelled:
                return LimitsProviderSnapshot(provider: .claude, session: nil, week: nil)
            }
        } catch {
            return claudeFailure(error, retryNotBefore: &retryNotBefore)
        }
    }

    private static func claudeFailure(
        _ error: Error, retryNotBefore: inout Date?
    ) -> LimitsProviderSnapshot {
        let message: String
        switch error {
        case ClaudeLimitsFetchError.unauthorized:
            message = "Claude session expired - run claude to re-login"
        case ClaudeLimitsFetchError.permissionDenied:
            message = "Claude token cannot read usage - run claude auth login --claudeai"
        case ClaudeLimitsFetchError.rateLimited(let after):
            let deadline = LimitsRefreshGate.backoffDeadline(retryAfter: after, now: Date())
            retryNotBefore = deadline
            message =
                "Rate limited by Claude - retrying at \(deadline.formatted(date: .omitted, time: .shortened))"
        case LimitsHistoryPersistenceError.failed:
            message = error.localizedDescription
        default:
            message = "Offline"
        }
        logger.error("\(message, privacy: .public)")
        return LimitsProviderSnapshot(
            provider: .claude, session: nil, week: nil, fable: nil, error: message)
    }

    private static func credentialFailureMessage(_ failure: ClaudeCredentialLookupFailure) -> String
    {
        switch failure {
        case .missing: "Claude Code token not found"
        case .rejected: "Claude session expired - run claude to re-login"
        case .malformed: "Credential data is invalid"
        case .timedOut: "Credential lookup timed out"
        case .oversized: "Credential data is too large"
        case .failed: "Could not read credentials"
        }
    }

    private static func fetchCodex() async -> LimitsProviderSnapshot {
        do {
            let limits = try await readCodexLimits()
            try persistHistory(
                provider: .codex, session: limits.session, week: limits.week, fable: nil)
            return LimitsProviderSnapshot(
                provider: .codex, session: limits.session, week: limits.week)
        } catch {
            return LimitsProviderSnapshot(
                provider: .codex, session: nil, week: nil,
                error: error.localizedDescription)
        }
    }

    private static func persistHistory(
        provider: LimitProvider, session: LimitWindow?, week: LimitWindow?,
        fable: LimitWindow? = nil
    ) throws {
        var history = LimitsHistory()
        guard history.append(provider: provider, session: session, week: week, fable: fable) else {
            throw LimitsHistoryPersistenceError.failed
        }
    }

    private static func refreshClaudeCredential(
        _ credential: ClaudeOAuthCredential, session: ClaudeCredentialSession
    ) async throws -> ClaudeOAuthCredential {
        let now = Date()
        guard let refreshToken = credential.usableRefreshToken(at: now) else {
            throw ClaudeLimitsFetchError.unauthorized
        }
        let response = try await fetchRefreshedClaudeToken(refreshToken: refreshToken)
        let data = try credential.updatedData(with: response, now: now)
        try await ClaudeCredentialStore.persist(data, source: credential.source)
        guard let refreshed = ClaudeOAuthCredential.decode(data, source: credential.source) else {
            throw ClaudeLimitsFetchError.unauthorized
        }
        session.store(refreshed)
        return refreshed
    }

    private static let limitsSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public static func fetchUsage(token: String) async throws -> ClaudeUsageParser.Result {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        let (data, resp) = try await limitsSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let after = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            .flatMap(TimeInterval.init)
        if let error = fetchError(statusCode: code, retryAfter: after) { throw error }
        return try ClaudeUsageParser.parse(data)
    }

    public static func fetchError(
        statusCode: Int, retryAfter: TimeInterval? = nil
    ) -> ClaudeLimitsFetchError? {
        switch statusCode {
        case 200: return nil
        case 401: return .unauthorized
        case 403: return .permissionDenied
        case 429: return .rateLimited(after: retryAfter)
        default: return .http(statusCode)
        }
    }

    private static func fetchRefreshedClaudeToken(refreshToken: String) async throws
        -> ClaudeOAuthRefreshResponse
    {
        var request = URLRequest(
            url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ])
        let (data, response) = try await limitsSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            return try JSONDecoder().decode(ClaudeOAuthRefreshResponse.self, from: data)
        case 400, 401, 403:
            throw ClaudeLimitsFetchError.unauthorized
        case 429:
            let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw ClaudeLimitsFetchError.rateLimited(after: after)
        default:
            throw ClaudeLimitsFetchError.http(code)
        }
    }

    private enum CodexLimitsError: LocalizedError {
        case executableMissing

        var errorDescription: String? { "The provider executable is not installed." }
    }

    private static func readCodexLimits() async throws -> ProviderLimits {
        guard let executable = codexExecutable() else { throw CodexLimitsError.executableMissing }
        return try await CodexLimitsReader.read(
            executable: executable, environment: CLIToolEnvironment.sanitized())
    }

    private static func codexExecutable() -> URL? {
        CLIToolEnvironment.executable(named: "codex")
    }
}

private enum LimitsHistoryPersistenceError: LocalizedError {
    case failed

    var errorDescription: String? { "The limits history could not be saved." }
}

public enum UsageLimitProviders {
    public static func enabled(claude: Bool, codex: Bool) -> [LimitProvider] {
        [(LimitProvider.claude, claude), (.codex, codex)].compactMap { provider, enabled in
            enabled ? provider : nil
        }
    }
}
