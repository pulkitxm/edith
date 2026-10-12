import CryptoKit
import Foundation

public struct ClaudeAccountLimits: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let limits: LimitsProviderSnapshot
    public let refreshedAt: Date

    public init(id: UUID, name: String, limits: LimitsProviderSnapshot, refreshedAt: Date) {
        self.id = id
        self.name = name
        self.limits = limits
        self.refreshedAt = refreshedAt
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
    public static let shared = ClaudeAccountLimitsCollector()
    private struct Cached {
        let snapshot: ClaudeAccountLimits
        let retryAt: Date
    }
    private var cached: [String: Cached] = [:]
    private var collecting = false
    private var followers: [CheckedContinuation<Void, Never>] = []

    public init() {}

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
        let read: @Sendable (ClaudeAccount) async -> (ClaudeAccount, ClaudeAccountLimits, Date) = {
            account in
            let limits: LimitsProviderSnapshot
            var retry = now.addingTimeInterval(60)
            do {
                limits = try await fetch(account, directory)
            } catch {
                if case ClaudeLimitsReader.Failure.rateLimited(let after) = error {
                    retry = now.addingTimeInterval(max(after ?? 1800, 60))
                }
                limits = LimitsProviderSnapshot(
                    provider: .claude, session: nil, week: nil,
                    error: error.localizedDescription)
            }
            return (
                account,
                ClaudeAccountLimits(
                    id: account.id, name: account.name, limits: limits, refreshedAt: now), retry
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
        return accounts.compactMap { account in
            guard let saved = cached[cacheKey(account)] else { return nil }
            return ClaudeAccountLimits(
                id: account.id, name: account.name, limits: saved.snapshot.limits,
                refreshedAt: saved.snapshot.refreshedAt)
        }
    }

    private func cacheKey(_ account: ClaudeAccount) -> String {
        let value =
            account.authentication == .browserLogin
            ? account.id.uuidString + (account.loginData ?? "")
            : account.authentication.rawValue + account.credential
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
