import CryptoKit
import EdithExtensionAccounts
import Foundation

public struct ClaudeAccountLimits: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let limits: LimitsProviderSnapshot
    public let refreshedAt: Date

    public init(id: UUID, name: String, limits: LimitsProviderSnapshot, refreshedAt: Date) {
        self.id = id; self.name = name; self.limits = limits; self.refreshedAt = refreshedAt
    }
}

public enum ClaudeAccountLimitsLayout {
    public static func inlineAccounts(_ accounts: [ClaudeAccountLimits], selectedID: String?)
        -> [ClaudeAccountLimits]
    {
        if accounts.count <= 2 { return accounts }
        return [accounts.first { $0.id.uuidString == selectedID } ?? accounts[0]]
    }

    public static func selected(_ accounts: [ClaudeAccountLimits], selectedID: String?)
        -> ClaudeAccountLimits?
    {
        accounts.first { $0.id.uuidString == selectedID } ?? accounts.first
    }
}

public actor ClaudeAccountLimitsCollector {
    private struct Cached: Sendable {
        let limits: LimitsProviderSnapshot
        let refreshedAt: Date
        let retryAt: Date
    }
    private var cached: [String: Cached] = [:]
    private var activeID: UUID?
    private var activeTask: Task<[(String, Cached)], Error>?
    private var clearing = false
    private var followers: [UUID: CheckedContinuation<Void, Error>] = [:]
    var followerCount: Int { followers.count }

    public init() {}

    public func refresh(
        accounts: [ClaudeAccount], directory: URL, now: Date = Date(),
        fetch: @escaping @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = {
            try await ClaudeLimitsReader.fetch(account: $0, directory: $1)
        }
    ) async throws -> [ClaudeAccountLimits] {
        try Task.checkCancellation()
        guard !clearing else { throw CancellationError() }
        guard accounts.count <= 64, Set(accounts.map(\.id)).count == accounts.count else {
            throw ClaudeAccountError.invalidRequest
        }
        for account in accounts { try account.validate() }
        if activeID != nil {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        followers[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelFollower(id) }
            }
            return try await refresh(
                accounts: accounts, directory: directory, now: now, fetch: fetch)
        }
        let keyed = accounts.map { (Self.cacheKey($0), $0) }
        let keys = Set(keyed.map { $0.0 })
        cached = cached.filter { keys.contains($0.key) }
        var scheduled = Set<String>()
        let pending = keyed.filter {
            scheduled.insert($0.0).inserted && (cached[$0.0].map { $0.retryAt <= now } ?? true)
        }
        let id = UUID()
        activeID = id
        let task = Task {
            try await withThrowingTaskGroup(of: (String, Cached).self) { group in
                let read: @Sendable ((String, ClaudeAccount)) async throws -> (String, Cached) = {
                    item in
                    let (key, account) = item
                    try Task.checkCancellation()
                    let limits: LimitsProviderSnapshot
                    var retryAt = now.addingTimeInterval(60)
                    do {
                        guard !account.isLoggedOut else {
                            throw ClaudeLimitsReader.Failure.missingToken
                        }
                        let fetched = try await fetch(account, directory)
                        try Task.checkCancellation()
                        limits = fetched
                    } catch {
                        if error is CancellationError { throw error }
                        try Task.checkCancellation()
                        if case ClaudeLimitsReader.Failure.rateLimited(let after) = error {
                            retryAt = now.addingTimeInterval(max(after ?? 1800, 60))
                        }
                        limits = .init(
                            provider: .claude, session: nil, week: nil,
                            error: Self.failureMessage(error))
                    }
                    return (key, Cached(limits: limits, refreshedAt: now, retryAt: retryAt))
                }
                var nextIndex = min(3, pending.count)
                for item in pending.prefix(3) { group.addTask { try await read(item) } }
                var values: [(String, Cached)] = []
                while let value = try await group.next() {
                    try Task.checkCancellation()
                    values.append(value)
                    if nextIndex < pending.count {
                        let item = pending[nextIndex]
                        nextIndex += 1
                        group.addTask { try await read(item) }
                    }
                }
                return values
            }
        }
        activeTask = task
        do {
            let values = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard activeID == id else { throw CancellationError() }
            for (key, value) in values { cached[key] = value }
            finish(id)
            return keyed.compactMap { key, account in
                cached[key].map {
                    .init(
                        id: account.id, name: account.name, limits: $0.limits,
                        refreshedAt: $0.refreshedAt)
                }
            }
        } catch {
            finish(id, failure: error)
            throw error
        }
    }

    public func clear() async {
        if clearing {
            _ = try? await activeTask?.value
            return
        }
        clearing = true
        defer { clearing = false }
        let task = activeTask
        activeID = nil
        cached = [:]
        let pending = followers
        followers = [:]
        for follower in pending.values { follower.resume(throwing: CancellationError()) }
        task?.cancel()
        _ = try? await task?.value
        activeTask = nil
    }

    private func finish(_ id: UUID, failure: Error? = nil) {
        guard activeID == id else { return }
        activeID = nil
        activeTask = nil
        let pending = followers
        followers = [:]
        for follower in pending.values {
            if let failure { follower.resume(throwing: failure) } else { follower.resume() }
        }
    }

    private func cancelFollower(_ id: UUID) {
        followers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private static func cacheKey(_ account: ClaudeAccount) -> String {
        let scope =
            account.authentication == .browserLogin || account.isLoggedOut
            ? account.id.uuidString : ""
        let value =
            scope + "\0" + account.authentication.rawValue + "\0"
            + account.credential + "\0" + (account.loginData ?? "") + "\0"
            + (account.remoteMachineID ?? "") + "\0" + String(account.isLoggedOut)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func failureMessage(_ error: Error) -> String {
        if let failure = error as? ClaudeLimitsReader.Failure {
            return failure.localizedDescription
        }
        return "Account limits are unavailable. Check this account's login in Sessions."
    }
}
