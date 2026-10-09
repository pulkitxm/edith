import EdithExtensionUI
import Foundation

public struct CompanionHealthSnapshot: Codable, Equatable, Sendable {
    public struct Check: Codable, Equatable, Sendable {
        public let name: String
        public let ok: Bool
        public let detail: String

        public init(name: String, ok: Bool, detail: String) {
            self.name = name
            self.ok = ok
            self.detail = detail
        }
    }

    public let checkedAt: Date
    public let endpoint: String
    public let reachable: Bool
    public let degraded: Bool
    public let checks: [Check]
    public let failure: String?
    public let skipped: Bool

    public init(
        checkedAt: Date, endpoint: String, reachable: Bool, degraded: Bool, checks: [Check],
        failure: String?, skipped: Bool
    ) {
        self.checkedAt = checkedAt
        self.endpoint = endpoint
        self.reachable = reachable
        self.degraded = degraded
        self.checks = checks
        self.failure = failure
        self.skipped = skipped
    }

    public static func unconfigured(at date: Date) -> CompanionHealthSnapshot {
        CompanionHealthSnapshot(
            checkedAt: date, endpoint: "", reachable: false, degraded: false, checks: [],
            failure: nil, skipped: true)
    }
}
