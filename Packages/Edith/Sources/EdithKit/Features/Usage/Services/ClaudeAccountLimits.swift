import CryptoKit
import Foundation

public struct ClaudeAccountLimits: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let limits: LimitsProviderSnapshot
    public let refreshedAt: Date
    public let retryAt: Date?

    public init(
        id: UUID, name: String, limits: LimitsProviderSnapshot, refreshedAt: Date,
        retryAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.limits = limits
        self.refreshedAt = refreshedAt
        self.retryAt = retryAt
    }
}

public enum ClaudeAccountLimitsLayout {
    public static func inlineAccounts(_ accounts: [ClaudeAccountLimits], selectedID: String?)
        -> [ClaudeAccountLimits]
    {
        if accounts.count <= 2 { return accounts }
        return [accounts.first { $0.id.uuidString == selectedID } ?? accounts[0]]
    }
}

public actor ClaudeAccountLimitsCollector {
    public static let shared = ClaudeAccountLimitsCollector(
        cacheFile: DataRoot.caches.appendingPathComponent("usage/account-limits.json"))
    private struct Cached: Codable, Sendable {
        let snapshot: ClaudeAccountLimits
        let retryAt: Date
    }
    private var cached: [String: Cached] = [:]
    private var collecting = false
    private var followers: [CheckedContinuation<Void, Never>] = []
    private let cacheFile: URL?

    public init(cacheFile: URL? = nil) {
        self.cacheFile = cacheFile
        if let cacheFile, let data = try? Data(contentsOf: cacheFile),
            let saved = try? JSONDecoder().decode([String: Cached].self, from: data)
        {
            cached = saved
        }
    }

    public func cachedSnapshots(accounts: [ClaudeAccount], now: Date = Date())
        -> [ClaudeAccountLimits]
    {
        if let cacheFile {
            if let handle = try? FileHandle(forReadingFrom: cacheFile) {
                defer { try? handle.close() }
                if let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576,
                    let saved = try? JSONDecoder().decode([String: Cached].self, from: data)
                {
                    cached = saved
                }
            }
        }
        return accounts.map { account in
            let snapshot = cached[cacheKey(account)]?.snapshot
            func fresh(_ window: LimitWindow?) -> LimitWindow? {
                window.flatMap { ($0.resetsAt ?? .distantFuture) > now ? $0 : nil }
            }
            let limits = LimitsProviderSnapshot(
                provider: .claude, session: fresh(snapshot?.limits.session),
                week: fresh(snapshot?.limits.week), fable: fresh(snapshot?.limits.fable),
                error: snapshot?.limits.error ?? (snapshot == nil ? "Loading limits." : nil))
            return ClaudeAccountLimits(
                id: account.id, name: account.name, limits: limits,
                refreshedAt: snapshot?.refreshedAt ?? now, retryAt: snapshot?.retryAt)
        }
    }

    public func refresh(
        accounts: [ClaudeAccount], directory: URL = ClaudeAccountStorage.directory,
        now: Date = Date(),
        fetch: @escaping @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = {
            try await ClaudeLimitsReader.fetch(account: $0, directory: $1)
        }
    ) async -> [ClaudeAccountLimits] {
        if collecting {
            await withCheckedContinuation { followers.append($0) }
            return await refresh(accounts: accounts, directory: directory, now: now, fetch: fetch)
        }
        collecting = true
        defer {
            collecting = false
            let pending = followers
            followers = []
            for follower in pending { follower.resume() }
        }
        let keys = Set(accounts.map(cacheKey))
        cached = cached.filter { keys.contains($0.key) }
        var scheduled = Set<String>()
        let pending = accounts.filter { account in
            let key = cacheKey(account)
            guard scheduled.insert(key).inserted else { return false }
            return cached[key].map { $0.retryAt <= now } ?? true
        }
        let previous = cached
        let read: @Sendable (ClaudeAccount) async -> (ClaudeAccount, ClaudeAccountLimits, Date) = {
            account in
            let limits: LimitsProviderSnapshot
            var retry = now.addingTimeInterval(60)
            var refreshedAt = now
            do {
                limits = try await fetch(account, directory)
            } catch {
                if case ClaudeLimitsReader.Failure.rateLimited(let after) = error {
                    retry = now.addingTimeInterval(max(after ?? 1800, 60))
                }
                let last = previous[self.cacheKey(account)]?.snapshot
                refreshedAt = last?.refreshedAt ?? now
                limits = LimitsProviderSnapshot(
                    provider: .claude, session: last?.limits.session, week: last?.limits.week,
                    fable: last?.limits.fable, grok: last?.limits.grok,
                    error: error.localizedDescription)
            }
            return (
                account,
                ClaudeAccountLimits(
                    id: account.id, name: account.name, limits: limits, refreshedAt: refreshedAt,
                    retryAt: limits.error == nil ? nil : retry), retry
            )
        }
        await withTaskGroup(of: (ClaudeAccount, ClaudeAccountLimits, Date).self) { group in
            let concurrencyLimit = 3
            var nextIndex = min(concurrencyLimit, pending.count)
            for account in pending.prefix(concurrencyLimit) {
                group.addTask { await read(account) }
            }
            while let (account, snapshot, retry) = await group.next() {
                cached[cacheKey(account)] = Cached(snapshot: snapshot, retryAt: retry)
                if nextIndex < pending.count {
                    let next = pending[nextIndex]
                    nextIndex += 1
                    group.addTask { await read(next) }
                }
            }
        }
        persistCache()
        return accounts.compactMap { account in
            guard let saved = cached[cacheKey(account)] else { return nil }
            return ClaudeAccountLimits(
                id: account.id, name: account.name, limits: saved.snapshot.limits,
                refreshedAt: saved.snapshot.refreshedAt, retryAt: saved.snapshot.retryAt)
        }
    }

    private func persistCache() {
        guard let cacheFile else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(cached).write(to: cacheFile, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: cacheFile.path)
        } catch {}
    }

    private nonisolated func cacheKey(_ account: ClaudeAccount) -> String {
        if let profileID = account.limitsProfileID {
            return "limits-profile-" + profileID.uuidString
        }
        let value =
            account.authentication == .browserLogin
            ? account.id.uuidString + (account.loginData ?? "")
            : account.authentication.rawValue + account.credential
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
