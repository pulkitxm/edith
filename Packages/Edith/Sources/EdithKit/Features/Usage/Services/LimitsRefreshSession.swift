import Foundation

public actor LimitsRefreshSession {
    public enum Decision: Sendable {
        case collect([LimitsProviderSnapshot])
        case cached(LimitsTopicSnapshot)
    }

    public static let shared = LimitsRefreshSession()
    private var collecting = false
    private var retryNotBefore: [LimitProvider: Date] = [:]
    private var latest: LimitsTopicSnapshot?
    private var followers: [CheckedContinuation<Decision, Never>] = []

    public init() {}

    var followerCount: Int { followers.count }

    public func requestImmediateRefresh() {
        retryNotBefore = [:]
    }

    public func begin(
        force: Bool, providers: [LimitProvider], now: Date = Date()
    ) async -> Decision {
        if collecting {
            return await withCheckedContinuation { followers.append($0) }
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
        collecting = true
        return .collect(paused)
    }

    func retryDeadline(for provider: LimitProvider) -> Date? {
        retryNotBefore[provider]
    }

    public func finish(_ snapshot: LimitsTopicSnapshot, retryNotBefore: [LimitProvider: Date]) {
        latest = snapshot
        self.retryNotBefore = retryNotBefore
        collecting = false
        let pending = followers
        followers = []
        for follower in pending { follower.resume(returning: .cached(snapshot)) }
    }
}
