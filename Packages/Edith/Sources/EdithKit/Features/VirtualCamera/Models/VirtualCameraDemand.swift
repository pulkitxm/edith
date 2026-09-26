import Foundation

public enum VirtualCameraDemand: Equatable, Sendable {
    case start
    case keepStreaming
    case scheduleStop
    case waitForStop
    case idle

    public static func next(
        installed: Bool, inUse: Bool, streaming: Bool, stopPending: Bool
    ) -> VirtualCameraDemand {
        if installed, inUse {
            return streaming ? .keepStreaming : .start
        }
        guard streaming else { return .idle }
        return stopPending ? .waitForStop : .scheduleStop
    }
}
