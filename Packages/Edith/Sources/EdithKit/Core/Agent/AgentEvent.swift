import Foundation

public struct AgentEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Level: String, Codable, CaseIterable, Sendable {
        case info
        case warning
        case error
    }

    public let id: UUID
    public let date: Date
    public let level: Level
    public let category: String
    public let name: String
    public let message: String
    public let duration: TimeInterval?
    public let taskID: UUID?

    public init(
        id: UUID = UUID(), date: Date = Date(), level: Level = .info,
        category: String, name: String, message: String, duration: TimeInterval? = nil,
        taskID: UUID? = nil
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.category = String(category.prefix(80))
        self.name = String(name.prefix(160))
        self.message = String(message.prefix(2_000))
        self.duration = duration
        self.taskID = taskID
    }
}

public enum AgentDiagnostics {
    public static let capacity = 500
    public static let runJob = AgentControlOperation.run.descriptor.id.rawValue
    public static let cancelJob = AgentControlOperation.cancel.descriptor.id.rawValue
}

public struct AgentEventDelta: Codable, Equatable, Sendable {
    public let dropped: Int
    public let appended: [AgentEvent]
    public let through: UInt64
    public let reset: Bool

    public init(dropped: Int, appended: [AgentEvent], through: UInt64, reset: Bool) {
        self.dropped = dropped
        self.appended = appended
        self.through = through
        self.reset = reset
    }
}

public enum AgentEventFeed {
    public static func reduce(
        log: [AgentEvent], through: inout UInt64, payload: Data
    ) -> [AgentEvent]? {
        guard let delta = try? AgentPayload.decode(AgentEventDelta.self, from: payload) else {
            return nil
        }
        if delta.reset {
            guard delta.through >= through else { return nil }
            through = delta.through
            return capped(delta.appended)
        }
        guard delta.through > through else { return nil }
        through = delta.through
        return apply(delta, to: log)
    }

    public static func apply(_ delta: AgentEventDelta, to log: [AgentEvent]) -> [AgentEvent] {
        var next = log
        if delta.dropped > 0 {
            next.removeFirst(min(delta.dropped, next.count))
        }
        var seen = Set(next.map(\.id))
        for event in delta.appended where seen.insert(event.id).inserted {
            next.append(event)
        }
        return capped(next)
    }

    private static func capped(_ events: [AgentEvent]) -> [AgentEvent] {
        guard events.count > AgentDiagnostics.capacity else { return events }
        return Array(events.suffix(AgentDiagnostics.capacity))
    }
}
