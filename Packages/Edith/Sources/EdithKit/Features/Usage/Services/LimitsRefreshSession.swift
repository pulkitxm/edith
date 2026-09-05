import Foundation

public actor LimitsRefreshSession {
    public enum Decision: Sendable {
        case collect
        case cached(LimitsTopicSnapshot)
    }

    public static let shared = LimitsRefreshSession()
    private var collecting = false
    private var retryNotBefore: Date?
    private var latest: LimitsTopicSnapshot?
    private var followers: [CheckedContinuation<Decision, Never>] = []

    public init() {}

    var followerCount: Int { followers.count }

    public func requestImmediateRefresh() {
        retryNotBefore = nil
    }

    public func begin(force: Bool, now: Date = Date()) async -> Decision {
        if collecting {
            return await withCheckedContinuation { followers.append($0) }
        }
        if !force, let retryNotBefore, retryNotBefore > now, let latest {
            return .cached(latest)
        }
        collecting = true
        return .collect
    }

    public func finish(_ snapshot: LimitsTopicSnapshot, retryNotBefore: Date?) {
        latest = snapshot
        self.retryNotBefore = retryNotBefore
        collecting = false
        let pending = followers
        followers = []
        for follower in pending { follower.resume(returning: .cached(snapshot)) }
    }
}
