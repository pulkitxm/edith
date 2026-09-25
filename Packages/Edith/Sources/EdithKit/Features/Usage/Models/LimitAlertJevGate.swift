import Foundation

public struct LimitAlertJevGate: Sendable {
    public static let threshold = 0.32
    public static let minimumConfidence = 0.5
    public static let timeout: TimeInterval = 10
    public static let purpose = "limit-alerts"
    public static let question = "worth_interrupting"
    static let instructions =
        "A usage-limit alert of kind `alert` is ready for the `provider` `window` limit at `percent` percent,"
        + " burning `burn_per_hour` percent an hour, projected to cap at `projected_cap` and resetting"
        + " at `resets_at`. The last alert for this window was `minutes_since_last_alert` minutes ago,"
        + " it is `local_hour` o'clock and the user was active recently: `recently_active`."
        + " Is this alert worth interrupting the user for right now?"

    public let decider: (any JevDeciding)?

    public init(decider: (any JevDeciding)?) {
        self.decider = decider
    }

    public static func request(for alert: LimitAlert) -> JevRequest {
        var fields = alert.facts
        fields["alert"] = alert.kind.rawValue.replacingOccurrences(of: "_", with: " ")
        return JevRequest(state: .fields(fields), questions: [question: .noul(instructions)])
    }

    public func allows(_ alert: LimitAlert) async -> Bool {
        guard !alert.kind.isCritical, let decider else { return true }
        let request = Self.request(for: alert)
        let answer = try? await Self.bounded(Self.timeout) {
            try await decider.decide(request, purpose: Self.purpose)
        }.answer(Self.question)
        guard let answer, let score = answer.noul,
            (answer.confidence ?? 1) >= Self.minimumConfidence
        else { return true }
        return score >= Self.threshold
    }

    static func bounded<T: Sendable>(
        _ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw JevError.unavailable("Jev did not answer in time")
            }
            return value
        }
    }
}
