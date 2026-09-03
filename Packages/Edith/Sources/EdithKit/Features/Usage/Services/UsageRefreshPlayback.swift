import Foundation

public enum UsageRefreshPlayback {
    public static func replay(
        events: [UsageRefreshEvent],
        dataDir: URL = Repo.dataDir,
        holdLock: Bool = false,
        failure: UsageRefreshFailure? = nil
    ) async throws {
        try replayBlocking(
            events: events, dataDir: dataDir, holdLock: holdLock, failure: failure)
    }

    public static func replayBlocking(
        events: [UsageRefreshEvent],
        dataDir: URL = Repo.dataDir,
        holdLock: Bool = false,
        failure: UsageRefreshFailure? = nil
    ) throws {
        if holdLock {
            try replayWhileLockHeld(events: events, dataDir: dataDir, failure: failure)
            return
        }
        guard let lock = UsageRefreshLock.acquire(at: UsageRefreshRunner.lockURL(dataDir: dataDir))
        else {
            throw UsageRefreshFailure.busy
        }
        defer { lock.release() }
        try write(events: events, dataDir: dataDir, failure: failure)
    }

    private static func replayWhileLockHeld(
        events: [UsageRefreshEvent],
        dataDir: URL,
        failure: UsageRefreshFailure?
    ) throws {
        guard UsageRefreshRunner.isRunning else { throw UsageRefreshFailure.busy }
        try write(events: events, dataDir: dataDir, failure: failure)
    }

    private static func write(
        events: [UsageRefreshEvent],
        dataDir: URL,
        failure: UsageRefreshFailure?
    ) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let sink = UsageRefreshSink(dataDir: dataDir, startedAt: Date())
        sink.begin()
        if let failure {
            switch failure {
            case let .reported(message):
                sink.write(.failure(message))
            default:
                throw failure
            }
        }
        for event in events { sink.write(event) }
        sink.finish()
    }
}
