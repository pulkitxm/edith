import Foundation

public enum LimitsRefreshGate {
    public static let stallTimeout: TimeInterval = 180
    public static let minimumBackoff: TimeInterval = 60
    public static let maximumBackoff: TimeInterval = 1800

    public enum Decision: Equatable {
        case start
        case recoverStalled
        case skipInFlight
        case skipBackoff
    }

    public static func decide(
        force: Bool, inFlightSince: Date?, retryNotBefore: Date?, now: Date,
        stallTimeout: TimeInterval = LimitsRefreshGate.stallTimeout
    ) -> Decision {
        if let inFlightSince, now.timeIntervalSince(inFlightSince) < stallTimeout {
            return .skipInFlight
        }
        if !force, let retryNotBefore, retryNotBefore > now { return .skipBackoff }
        return inFlightSince == nil ? .start : .recoverStalled
    }

    public static func backoffDeadline(retryAfter: TimeInterval?, now: Date) -> Date {
        let requested = retryAfter ?? maximumBackoff
        return now.addingTimeInterval(min(max(requested, minimumBackoff), maximumBackoff))
    }
}
