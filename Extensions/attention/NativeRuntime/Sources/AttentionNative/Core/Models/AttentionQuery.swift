@_implementationOnly import EdithExtensionSupport_attention_native
@_implementationOnly import EdithExtensionUI_attention_native
import Foundation

struct AttentionTimeWindow: Codable, Equatable, Hashable, Sendable {
    static let all = AttentionTimeWindow()
    static let weekdays: Set<Int> = [2, 3, 4, 5, 6]
    static let weekends: Set<Int> = [1, 7]

    var weekdays: Set<Int>
    var startHour: Int
    var endHour: Int

    init(weekdays: Set<Int> = [], startHour: Int = 0, endHour: Int = 24) {
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        self.startHour = max(0, min(23, startHour))
        self.endHour = max(1, min(24, endHour))
    }

    private enum CodingKeys: String, CodingKey { case weekdays, startHour, endHour }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            weekdays: Set(try container.decode([Int].self, forKey: .weekdays)),
            startHour: try container.decode(Int.self, forKey: .startHour),
            endHour: try container.decode(Int.self, forKey: .endHour))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(weekdays.sorted(), forKey: .weekdays)
        try container.encode(startHour, forKey: .startHour)
        try container.encode(endHour, forKey: .endHour)
    }

    var allDays: Bool { weekdays.isEmpty || weekdays.count == 7 }
    var allHours: Bool { startHour == 0 && endHour == 24 }
    var isAll: Bool { allDays && allHours }

    func allows(weekday: Int) -> Bool { allDays || weekdays.contains(weekday) }

    func allows(hour: Int) -> Bool {
        if allHours { return true }
        if startHour < endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour
    }

    func allows(_ date: Date, calendar: Calendar) -> Bool {
        allows(weekday: calendar.component(.weekday, from: date))
            && allows(hour: calendar.component(.hour, from: date))
    }

    func apply(_ events: [AttentionEvent], calendar: Calendar) -> [AttentionEvent] {
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

enum AttentionSummaryPart: String, Codable, CaseIterable, Hashable, Sendable {
    case overview
    case timeline
    case breakdown
    case agents
    case focus

    static let overviewDimensions = [
        AttentionTag.page, AttentionTag.machine, AttentionTag.agent, AttentionTag.project,
    ]
}

extension AttentionSummary {
    func preserving(
        _ retained: Set<AttentionSummaryPart>, from current: AttentionSummary,
        loading parts: Set<AttentionSummaryPart>
    ) -> AttentionSummary {
        guard current.from == from, current.to == to else { return self }
        var copy = self
        if parts.isDisjoint(with: [.overview, .breakdown]),
            !retained.isDisjoint(with: [.overview, .breakdown])
        {
            copy.entities = current.entities
        }
        if !parts.contains(.overview), retained.contains(.overview) {
            copy.music = current.music
            copy.transitions = current.transitions
        }
        if !parts.contains(.breakdown), retained.contains(.breakdown) {
            copy.dimensions = current.dimensions
        } else if !parts.contains(.breakdown), !parts.contains(.overview),
            retained.contains(.overview)
        {
            copy.dimensions = current.dimensions
        }
        let singleDay = to.timeIntervalSince(from) <= 90_000
        if !parts.contains(.timeline), !(parts.contains(.overview) && singleDay),
            retained.contains(.timeline) || (retained.contains(.overview) && singleDay)
        {
            copy.spans = current.spans
        }
        if !parts.contains(.agents), retained.contains(.agents) {
            copy.agents.sessions = current.agents.sessions
            copy.agents.concurrency = current.agents.concurrency
        } else if !parts.contains(.agents), !(parts.contains(.overview) && singleDay),
            retained.contains(.overview) && singleDay
        {
            copy.agents.concurrency = current.agents.concurrency
        }
        return copy
    }

    func trimmed(to parts: Set<AttentionSummaryPart>) -> AttentionSummary {
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
        if parts.isDisjoint(with: [.overview, .breakdown]) { copy.entities = [] }
        if !parts.contains(.overview) {
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
