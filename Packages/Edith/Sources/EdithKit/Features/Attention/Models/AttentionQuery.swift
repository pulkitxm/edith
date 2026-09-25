import Foundation

public struct AttentionTimeWindow: Codable, Equatable, Hashable, Sendable {
    public static let all = AttentionTimeWindow()
    public static let weekdays: Set<Int> = [2, 3, 4, 5, 6]
    public static let weekends: Set<Int> = [1, 7]

    public var weekdays: Set<Int>
    public var startHour: Int
    public var endHour: Int

    public init(weekdays: Set<Int> = [], startHour: Int = 0, endHour: Int = 24) {
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        self.startHour = max(0, min(23, startHour))
        self.endHour = max(1, min(24, endHour))
    }

    private enum CodingKeys: String, CodingKey { case weekdays, startHour, endHour }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            weekdays: Set(try container.decode([Int].self, forKey: .weekdays)),
            startHour: try container.decode(Int.self, forKey: .startHour),
            endHour: try container.decode(Int.self, forKey: .endHour))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(weekdays.sorted(), forKey: .weekdays)
        try container.encode(startHour, forKey: .startHour)
        try container.encode(endHour, forKey: .endHour)
    }

    public var allDays: Bool { weekdays.isEmpty || weekdays.count == 7 }
    public var allHours: Bool { startHour == 0 && endHour == 24 }
    public var isAll: Bool { allDays && allHours }

    public func allows(weekday: Int) -> Bool { allDays || weekdays.contains(weekday) }

    public func allows(hour: Int) -> Bool {
        if allHours { return true }
        if startHour < endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour
    }

    public func allows(_ date: Date, calendar: Calendar) -> Bool {
        allows(weekday: calendar.component(.weekday, from: date))
            && allows(hour: calendar.component(.hour, from: date))
    }

    public func apply(_ events: [AttentionEvent], calendar: Calendar) -> [AttentionEvent] {
        guard !isAll else { return events }
        var result: [AttentionEvent] = []
        result.reserveCapacity(events.count)
        for event in events {
            var cursor = event.startedAt
            var runStart: Date?
            while cursor < event.endedAt {
                let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end ?? event.endedAt
                if allows(cursor, calendar: calendar) {
                    if runStart == nil { runStart = cursor }
                } else if let start = runStart {
                    if let part = event.clipped(from: start, to: cursor) { result.append(part) }
                    runStart = nil
                }
                cursor = min(event.endedAt, hourEnd)
            }
            if let start = runStart, let part = event.clipped(from: start, to: event.endedAt) {
                result.append(part)
            }
        }
        return result
    }
}

public enum AttentionSummaryPart: String, Codable, CaseIterable, Hashable, Sendable {
    case overview
    case timeline
    case breakdown
    case agents
    case focus

    public static let overviewDimensions = [
        AttentionTag.page, AttentionTag.machine, AttentionTag.agent, AttentionTag.project,
    ]
}

extension AttentionSummary {
    public func trimmed(to parts: Set<AttentionSummaryPart>) -> AttentionSummary {
        var copy = self
        let singleDay = to.timeIntervalSince(from) <= 90_000
        let wantsSpans = parts.contains(.timeline) || (parts.contains(.overview) && singleDay)
        if !wantsSpans { copy.spans = [] }
        if !parts.contains(.breakdown) {
            copy.dimensions =
                parts.contains(.overview)
                ? dimensions.filter { AttentionSummaryPart.overviewDimensions.contains($0.key) }
                    .map {
                        AttentionDimension(
                            key: $0.key, rows: Array($0.rows.prefix(8)), total: $0.total)
                    }
                : []
        }
        if !parts.contains(.overview) {
            copy.entities = []
            copy.music = []
            copy.transitions = []
        }
        if !parts.contains(.agents) {
            copy.agents.sessions = []
            if !(parts.contains(.overview) && singleDay) { copy.agents.concurrency = [] }
        }
        return copy
    }
}
