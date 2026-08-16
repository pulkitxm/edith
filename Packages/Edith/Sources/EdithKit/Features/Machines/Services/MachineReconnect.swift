import Foundation

public enum MachineReconnect {
    public static let quietFailures = 5
    public static let longestDelay: TimeInterval = 30

    public static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let steps: [TimeInterval] = [1, 2, 4, 8, 15]
        guard failures <= steps.count else { return longestDelay }
        return steps[failures - 1]
    }

    public static func state(afterFailures failures: Int, reason: String)
        -> MachineConnectionState
    {
        failures <= quietFailures ? .reconnecting : .failed(message: reason)
    }
}
