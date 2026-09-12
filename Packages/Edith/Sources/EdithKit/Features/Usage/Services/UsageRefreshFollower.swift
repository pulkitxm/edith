import Foundation

public enum UsageRefreshFollower {
    public static func follow(
        dataDir: URL = Repo.dataDir,
        runID: String? = nil,
        startTimeout: TimeInterval = 1_800,
        pollInterval: Duration = .milliseconds(150),
        onEvent: @escaping @Sendable (UsageRefreshEvent) -> Void = { _ in }
    ) async throws -> UsageRefreshResult {
        let startedAt = Date()
        if let runID, UUID(uuidString: runID) == nil {
            throw UsageRefreshFailure.reported("invalid usage refresh identifier")
        }
        let events =
            runID.map { UsageRefreshRunner.runEventsURL(runID: $0, dataDir: dataDir) }
            ?? UsageRefreshRunner.eventsURL(dataDir: dataDir)
        let lock = UsageRefreshRunner.lockURL(dataDir: dataDir)
        var delivered = 0
        var collected: [UsageRefreshEvent] = []

        while true {
            try Task.checkCancellation()
            if runID != nil, !FileManager.default.fileExists(atPath: events.path) {
                guard Date().timeIntervalSince(startedAt) < startTimeout else {
                    throw UsageRefreshFailure.reported("the requested usage refresh did not start")
                }
                try await Task.sleep(for: pollInterval)
                continue
            }
            let parsed = read(events)
            while delivered < parsed.count {
                let event = parsed[delivered]
                delivered += 1
                collected.append(event)
                onEvent(event)
                if case let .failure(message) = event {
                    throw UsageRefreshFailure.reported(message)
                }
                if case let .finished(seconds) = event {
                    return UsageRefreshResult(
                        events: collected, seconds: seconds, startedAt: startedAt)
                }
            }
            guard UsageRefreshLock.isHeld(at: lock) else {
                let parsed = read(events)
                while delivered < parsed.count {
                    let event = parsed[delivered]
                    delivered += 1
                    collected.append(event)
                    onEvent(event)
                    if case let .failure(message) = event {
                        throw UsageRefreshFailure.reported(message)
                    }
                    if case let .finished(seconds) = event {
                        return UsageRefreshResult(
                            events: collected, seconds: seconds, startedAt: startedAt)
                    }
                }
                throw UsageRefreshFailure.exited(
                    -1, "the refresh that was already running stopped without finishing")
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    public static func runID(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let first = text.split(separator: "\n").first, first.hasPrefix("run\t")
        else { return nil }
        return String(first.dropFirst(4))
    }

    public static func read(_ url: URL) -> [UsageRefreshEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { UsageRefreshEvent.parse(String($0)) }
    }
}
