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
        let startedAt = Date()
        var retryNotBefore: Date?
        switch await refreshSession.begin(force: force, now: startedAt) {
        case .cached(let snapshot): return snapshot
        case .collect: break
        }
        let providers = enabledProviders(defaults: defaults)
        var snapshots: [LimitsProviderSnapshot] = []
        var topFailure: String?
        for provider in providers {
            switch provider {
            case .claude:
                let result = await fetchClaude(
                    credentialSession: credentialSession, retryNotBefore: &retryNotBefore)
                snapshots.append(result)
                if result.error != nil { topFailure = result.error }
            case .codex:
                let result = await fetchCodex()
                snapshots.append(result)
                if result.error != nil { topFailure = result.error }
            }
        }
        if snapshots.contains(where: { $0.session != nil || $0.week != nil || $0.fable != nil }) {
            announce(IPC.Name.limitsUpdated)
        }
        let snapshot = LimitsTopicSnapshot(
            refreshedAt: startedAt, providers: snapshots, failure: topFailure)
        await refreshSession.finish(snapshot, retryNotBefore: retryNotBefore)
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

    private struct CodexWindow: Decodable {
        let usedPercent: Double
        let windowDurationMins: Double?
        let resetsAt: Double?
    }

    private struct CodexSnapshot: Decodable {
        let primary: CodexWindow?
        let secondary: CodexWindow?
    }

    private struct CodexRateLimitsResult: Decodable {
        let rateLimits: CodexSnapshot?
    }

    private struct CodexResponse: Decodable {
        let id: Int?
        let result: CodexRateLimitsResult?
    }

    private enum CodexLimitsError: LocalizedError {
        case executableMissing
        case unavailable

        var errorDescription: String? {
            switch self {
            case .executableMissing: return "Codex is not installed"
            case .unavailable: return "Codex limits are unavailable"
            }
        }
    }

    private static let codexReadTimeout: TimeInterval = 25

    private static func readCodexLimits() async throws -> ProviderLimits {
        guard let executable = codexExecutable() else { throw CodexLimitsError.executableMissing }
        let input = Data(
            """
            {"method":"initialize","id":0,"params":{"clientInfo":{"name":"edith","title":"Edith","version":"1.0"}}}
            {"method":"initialized","params":{}}
            {"method":"account/rateLimits/read","id":1,"params":{}}
            """.utf8)
        var lines: [String] = []
        let result = try await CLICommandRunner.run(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", "\(executable.path) app-server"],
                environment: CLIToolEnvironment.sanitized(),
                timeout: codexReadTimeout,
                maximumOutputBytes: 1_048_576,
                standardInputData: input,
                discardsStandardError: true,
                terminatesProcessGroup: true),
            onLine: { lines.append($0) })
        guard result.terminationStatus == 0 else { throw CodexLimitsError.unavailable }
        guard
            let line = lines.first(where: { line in
                guard let data = line.data(using: .utf8),
                    let value = try? JSONDecoder().decode(CodexResponse.self, from: data),
                    value.id == 1
                else { return false }
                return true
            }),
            let data = line.data(using: .utf8),
            let response = try? JSONDecoder().decode(CodexResponse.self, from: data),
            let snapshot = response.result?.rateLimits
        else { throw CodexLimitsError.unavailable }
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        let mapped = windows.map { window in
            (
                duration: window.windowDurationMins ?? 0,
                value: LimitWindow(
                    percent: window.usedPercent,
                    resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:)))
            )
        }.sorted { $0.duration < $1.duration }
        let session = mapped.first { $0.duration > 0 && $0.duration < 7 * 24 * 60 }?.value
        let week = mapped.last { $0.duration >= 7 * 24 * 60 }?.value ?? mapped.last?.value
        return ProviderLimits(provider: .codex, session: session, week: week)
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
