import Foundation

struct UsageRefreshObservation: Sendable {
    let startedAt: Date
    let events: [UsageRefreshEvent]
    var seconds: Double {
        events.compactMap {
            if case .finished(let seconds) = $0 { return seconds }
            return nil
        }.last
            ?? Date().timeIntervalSince(startedAt)
    }
}

final class UsageRefreshRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = Date()
    private var events: [UsageRefreshEvent] = []

    func record(_ event: UsageRefreshEvent) { lock.withLock { events.append(event) } }
    var snapshot: UsageRefreshObservation {
        lock.withLock { UsageRefreshObservation(startedAt: startedAt, events: events) }
    }
}
