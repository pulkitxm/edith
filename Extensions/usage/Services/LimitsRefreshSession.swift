import Foundation

public actor LimitsRefreshSession {
    public struct Lease: Sendable {
        public let id: UUID
        public let paused: [LimitsProviderSnapshot]
    }

    public enum Decision: Sendable {
        case collect(Lease)
        case cached(LimitsTopicSnapshot)
        case cancelled
    }

    public static let shared = LimitsRefreshSession()
    private var activeID: UUID?
    private var retryNotBefore: [LimitProvider: Date] = [:]
    private var latest: LimitsTopicSnapshot?
    private var followers: [UUID: CheckedContinuation<Decision, Never>] = [:]

    public init() {}

    var followerCount: Int { followers.count }

    public func requestImmediateRefresh() {
        retryNotBefore = [:]
    }

    public func begin(
        force: Bool, providers: [LimitProvider], now: Date = Date()
    ) async -> Decision {
        guard !Task.isCancelled else { return .cancelled }
        if activeID != nil {
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(returning: .cancelled)
                    } else {
                        followers[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelFollower(id) }
            }
        }
        let paused =
            force
            ? []
            : (latest?.providers ?? []).filter {
                providers.contains($0.provider)
                    && (retryNotBefore[$0.provider] ?? .distantPast) > now
            }
        if !providers.isEmpty, paused.count == providers.count, let latest {
            return .cached(
                LimitsTopicSnapshot(
                    refreshedAt: latest.refreshedAt, providers: paused,
                    failure: paused.compactMap(\.error).first))
        }
        let id = UUID()
        activeID = id
        return .collect(Lease(id: id, paused: paused))
    }

    func retryDeadline(for provider: LimitProvider) -> Date? {
        retryNotBefore[provider]
    }

    @discardableResult
    public func finish(
        _ snapshot: LimitsTopicSnapshot, retryNotBefore: [LimitProvider: Date], lease: UUID
    ) -> Bool {
        guard activeID == lease else { return false }
        latest = snapshot
        self.retryNotBefore = retryNotBefore
        activeID = nil
        let pending = followers
        followers = [:]
        for follower in pending.values { follower.resume(returning: .cached(snapshot)) }
        return true
    }

    public func abort(lease: UUID? = nil) {
        if let lease, activeID != lease { return }
        activeID = nil
        let pending = followers
        followers = [:]
        for follower in pending.values { follower.resume(returning: .cancelled) }
    }

    public func clear() {
        abort()
        latest = nil
        retryNotBefore = [:]
    }

    private func cancelFollower(_ id: UUID) {
        followers.removeValue(forKey: id)?.resume(returning: .cancelled)
    }

}
