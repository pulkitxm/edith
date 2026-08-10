import Foundation

public enum MachineResourcePolicy {
    public static let localProcessSampleStride = 5
    public static let foregroundDockerPollInterval: TimeInterval = 4
    public static let backgroundDockerPollInterval: TimeInterval = 30
    public static let latencyProbeInterval: TimeInterval = 30
    public static let mountCheckInterval: TimeInterval = 20

    public static func shouldRefreshProcesses(sampleIndex: Int, stride: Int) -> Bool {
        sampleIndex.isMultiple(of: max(1, stride))
    }

    public static func dockerPollInterval(observerCount: Int) -> TimeInterval {
        observerCount > 0 ? foregroundDockerPollInterval : backgroundDockerPollInterval
    }
}
