import Darwin
import EdithCore
import Foundation
import os

public struct LimitsProviderSnapshot: Codable, Equatable, Sendable {
    public let provider: LimitProvider
    public let session: LimitWindow?
    public let week: LimitWindow?
    public let fable: LimitWindow?
    public let grok: GrokAllowance?
    public let error: String?

    public init(
        provider: LimitProvider, session: LimitWindow?, week: LimitWindow?,
        fable: LimitWindow? = nil, grok: GrokAllowance? = nil, error: String? = nil
    ) {
        self.provider = provider
        self.session = session
        self.week = week
        self.fable = fable
        self.grok = grok
        self.error = error
    }

    public func window(for slot: LimitWindowSlot) -> LimitWindow? {
        switch slot {
        case .session: session
        case .week: week
        case .fable: fable
        }
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
        let cursor = defaults.object(forKey: AppStorageKeys.Limits.cursorEnabled) as? Bool ?? true
        let grok = defaults.object(forKey: AppStorageKeys.Limits.grokEnabled) as? Bool ?? true
        return UsageLimitProviders.enabled(claude: claude, codex: codex, cursor: cursor, grok: grok)
    }

    public static func providerEnabled(
        _ provider: LimitProvider, defaults: UserDefaults = SharedDefaults.store
    ) -> Bool {
        let key: String
        switch provider {
        case .claude: key = AppStorageKeys.Limits.claudeEnabled
        case .codex: key = AppStorageKeys.Limits.codexEnabled
        case .cursor: key = AppStorageKeys.Limits.cursorEnabled
        case .grok: key = AppStorageKeys.Limits.grokEnabled
        }
        return defaults.object(forKey: key) as? Bool ?? true
    }

    public static func refresh(
        force: Bool = false, defaults: UserDefaults = SharedDefaults.store,
        refreshSession: LimitsRefreshSession = .shared,
        connectClaude: @Sendable () -> Void = { LimitsCollector.connectClaudeStatusLine() },
        announce: @Sendable (Notification.Name) -> Void = { IPC.post($0) }
    ) async -> LimitsTopicSnapshot {
        await collect(
            providers: enabledProviders(defaults: defaults), force: force,
            refreshSession: refreshSession, announce: announce
        ) { provider in
            switch provider {
            case .claude:
                connectClaude()
                return await fetchClaude()
            case .codex:
                return (await fetchCodex(), nil)
            case .cursor:
                return await fetchCursor()
            case .grok:
                return await fetchGrok()
            }
        }
    }

    public static func connectClaudeStatusLine() {
        guard !AppBuildIdentity.isDevelopment else { return }
        do {
            try ClaudeStatusLine.ensureConnected()
        } catch {
            logger.error(
                "claude status line not connected: \(error.localizedDescription, privacy: .public)")
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

    static func fetchClaude(
        now: Date = Date(),
        fetch: () async throws -> LimitsProviderSnapshot = {
            try await ClaudeLimitsReader.fetch()
        },
        fallback: () -> LimitsProviderSnapshot = { ClaudeStatusLine.snapshot() },
        persist: (LimitsProviderSnapshot) throws -> Void = { snapshot in
            try persistHistory(
                provider: .claude, session: snapshot.session, week: snapshot.week,
                fable: snapshot.fable)
        }
    ) async -> (LimitsProviderSnapshot, Date?) {
        do {
            let snapshot = try await fetch()
            try persist(snapshot)
            return (snapshot, nil)
        } catch {
            let saved = fallback()
            let message = error.localizedDescription
            let deadline: Date?
            if case ClaudeLimitsReader.Failure.rateLimited(let after) = error {
                deadline = now.addingTimeInterval(max(after ?? 1800, 60))
            } else {
                deadline = nil
            }
            return (
                LimitsProviderSnapshot(
                    provider: .claude, session: saved.session,
                    week: saved.session == nil ? nil : saved.week,
                    fable: saved.session == nil ? nil : saved.fable, error: message), deadline
            )
        }
    }

    private static func fetchCursor() async -> (LimitsProviderSnapshot, Date?) {
        guard var material = CursorCredentialStore.load() else {
            return (
                LimitsProviderSnapshot(
                    provider: .cursor, session: nil, week: nil, error: "Cursor token not found"),
                nil
            )
        }
        var refreshed = false
        if CursorCredentialStore.expiresSoon(material.accessToken), material.refreshToken != nil {
            do {
                material = try await refreshCursor(material)
                refreshed = true
            } catch CursorLimitsReader.Failure.unauthorized {
                return (
                    LimitsProviderSnapshot(
                        provider: .cursor, session: nil, week: nil,
                        error: CursorLimitsReader.Failure.unauthorized.localizedDescription),
                    nil
                )
            } catch {}
        }
        do {
            let limits = try await CursorLimitsReader.fetch(token: material.accessToken)
            try persistHistory(
                provider: .cursor, session: limits.session, week: limits.week, fable: nil)
            return (
                LimitsProviderSnapshot(
                    provider: .cursor, session: limits.session, week: limits.week), nil
            )
        } catch CursorLimitsReader.Failure.unauthorized
            where !refreshed && material.refreshToken != nil
        {
            do {
                let latest = try await refreshCursor(material)
                let limits = try await CursorLimitsReader.fetch(token: latest.accessToken)
                try persistHistory(
                    provider: .cursor, session: limits.session, week: limits.week, fable: nil)
                return (
                    LimitsProviderSnapshot(
                        provider: .cursor, session: limits.session, week: limits.week), nil
                )
            } catch {
                return cursorFailure(error)
            }
        } catch {
            return cursorFailure(error)
        }
    }

    private static func refreshCursor(
        _ material: CursorCredentialStore.Material
    ) async throws -> CursorCredentialStore.Material {
        guard let refreshToken = material.refreshToken else {
            throw CursorLimitsReader.Failure.unauthorized
        }
        let refreshed = try await CursorLimitsReader.refresh(refreshToken: refreshToken)
        var next = material
        next.accessToken = refreshed.accessToken
        if let replacement = refreshed.refreshToken { next.refreshToken = replacement }
        if next.file != nil { try? CursorCredentialStore.save(next) }
        return next
    }

    private static func cursorFailure(_ error: Error) -> (LimitsProviderSnapshot, Date?) {
        var retryNotBefore: Date?
        let message: String
        switch error {
        case CursorLimitsReader.Failure.unauthorized:
            message = CursorLimitsReader.Failure.unauthorized.localizedDescription
        case CursorLimitsReader.Failure.rateLimited(let after):
            let deadline = LimitsRefreshGate.backoffDeadline(retryAfter: after, now: Date())
            retryNotBefore = deadline
            message =
                "Rate limited by Cursor - retrying at \(deadline.formatted(date: .omitted, time: .shortened))"
        case CursorLimitsReader.Failure.unavailable:
            message = CursorLimitsReader.Failure.unavailable.localizedDescription
        case CursorLimitsReader.Failure.malformed:
            message = CursorLimitsReader.Failure.malformed.localizedDescription
        case LimitsHistoryPersistenceError.failed:
            message = error.localizedDescription
        default:
            message = "Offline"
        }
        logger.error("\(message, privacy: .public)")
        return (
            LimitsProviderSnapshot(
                provider: .cursor, session: nil, week: nil, error: message), retryNotBefore
        )
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

    private static func fetchGrok() async -> (LimitsProviderSnapshot, Date?) {
        guard var material = GrokCredentialStore.load() else {
            return (
                LimitsProviderSnapshot(
                    provider: .grok, session: nil, week: nil, error: "Grok token not found"),
                nil
            )
        }
        var refreshed = false
        if GrokCredentialStore.expiresSoon(material.expiresAt), material.refreshToken != nil {
            do {
                material = try await refreshGrok(material)
                refreshed = true
            } catch GrokLimitsReader.Failure.unauthorized {
                return (
                    LimitsProviderSnapshot(
                        provider: .grok, session: nil, week: nil,
                        error: GrokLimitsReader.Failure.unauthorized.localizedDescription),
                    nil
                )
            } catch {}
        }
        do {
            let limits = try await GrokLimitsReader.fetch(
                token: material.accessToken, tier: GrokCredentialStore.tierDisplay())
            try persistHistory(
                provider: .grok, session: nil, week: limits.week, grok: limits.grok)
            return (
                LimitsProviderSnapshot(
                    provider: .grok, session: nil, week: limits.week, grok: limits.grok),
                nil
            )
        } catch GrokLimitsReader.Failure.unauthorized
            where !refreshed && material.refreshToken != nil
        {
            do {
                let latest = try await refreshGrok(material)
                let limits = try await GrokLimitsReader.fetch(
                    token: latest.accessToken, tier: GrokCredentialStore.tierDisplay())
                try persistHistory(
                    provider: .grok, session: nil, week: limits.week, grok: limits.grok)
                return (
                    LimitsProviderSnapshot(
                        provider: .grok, session: nil, week: limits.week, grok: limits.grok),
                    nil
                )
            } catch {
                return grokFailure(error)
            }
        } catch {
            return grokFailure(error)
        }
    }

    private static func refreshGrok(
        _ material: GrokCredentialStore.Material
    ) async throws -> GrokCredentialStore.Material {
        guard let refreshToken = material.refreshToken else {
            throw GrokLimitsReader.Failure.unauthorized
        }
        let refreshed = try await GrokLimitsReader.refresh(
            refreshToken: refreshToken, clientID: material.clientID)
        var next = material
        next.accessToken = refreshed.accessToken
        if let replacement = refreshed.refreshToken { next.refreshToken = replacement }
        next.expiresAt = refreshed.expiresAt
        try? GrokCredentialStore.save(next)
        return next
    }

    private static func grokFailure(_ error: Error) -> (LimitsProviderSnapshot, Date?) {
        var retryNotBefore: Date?
        let message: String
        switch error {
        case GrokLimitsReader.Failure.unauthorized:
            message = GrokLimitsReader.Failure.unauthorized.localizedDescription
        case GrokLimitsReader.Failure.rateLimited(let after):
            let deadline = LimitsRefreshGate.backoffDeadline(retryAfter: after, now: Date())
            retryNotBefore = deadline
            message =
                "Rate limited by Grok - retrying at \(deadline.formatted(date: .omitted, time: .shortened))"
        case GrokLimitsReader.Failure.unavailable:
            message = GrokLimitsReader.Failure.unavailable.localizedDescription
        case GrokLimitsReader.Failure.malformed:
            message = GrokLimitsReader.Failure.malformed.localizedDescription
        case LimitsHistoryPersistenceError.failed:
            message = error.localizedDescription
        default:
            message = "Offline"
        }
        logger.error("\(message, privacy: .public)")
        return (
            LimitsProviderSnapshot(
                provider: .grok, session: nil, week: nil, error: message), retryNotBefore
        )
    }

    private static func persistHistory(
        provider: LimitProvider, session: LimitWindow?, week: LimitWindow?,
        fable: LimitWindow? = nil, grok: GrokAllowance? = nil
    ) throws {
        var history = LimitsHistory()
        guard
            history.append(
                provider: provider, session: session, week: week, fable: fable, grok: grok)
        else {
            throw LimitsHistoryPersistenceError.failed
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
    public static func enabled(claude: Bool, codex: Bool, cursor: Bool, grok: Bool)
        -> [LimitProvider]
    {
        [
            (LimitProvider.claude, claude), (.codex, codex), (.cursor, cursor), (.grok, grok),
        ].compactMap { provider, enabled in
            enabled ? provider : nil
        }
    }
}
