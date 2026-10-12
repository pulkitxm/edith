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
        let account: ClaudeAccount
        let snapshot: ClaudeAccountLimits
        let retryAt: Date
    }
    private var cached: [UUID: Cached] = [:]
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
        let ids = Set(accounts.map(\.id))
        cached = cached.filter { ids.contains($0.key) }
        var result: [UUID: ClaudeAccountLimits] = [:]
        let pending = accounts.filter { account in
            if let saved = cached[account.id], saved.account == account, saved.retryAt > now {
                result[account.id] = saved.snapshot
                return false
            }
            return true
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
                cached[account.id] = Cached(account: account, snapshot: snapshot, retryAt: retry)
                result[account.id] = snapshot
                if nextIndex < pending.count {
                    let next = pending[nextIndex]
                    nextIndex += 1
                    group.addTask { await read(next) }
                }
            }
        }
        return accounts.compactMap { result[$0.id] }
    }
}
