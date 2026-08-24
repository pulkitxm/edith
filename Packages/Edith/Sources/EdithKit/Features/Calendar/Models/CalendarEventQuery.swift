import Foundation

public struct CalendarEventQuery: Codable, Equatable, Sendable {
    public static let initialDays = 14
    public static let pageDays = 14
    public static let maximumDays = 120

    public let days: Int
    public let start: Date
    public let end: Date

    public init(days: Int, now: Date = Date(), calendar: Calendar = .current) {
        let boundedDays = min(max(days, 0), Self.maximumDays)
        let start = calendar.startOfDay(for: now)
        self.days = boundedDays
        self.start = start
        self.end =
            boundedDays == 0
            ? now : calendar.date(byAdding: .day, value: boundedDays, to: start) ?? now
    }

    public func contains(_ event: CalendarEventPayload) -> Bool {
        event.end >= start && event.start <= end
    }
}

public struct CalendarEventPagination: Equatable, Sendable {
    public private(set) var days: Int

    public init(days: Int = CalendarEventQuery.initialDays) {
        self.days = min(max(days, 0), CalendarEventQuery.maximumDays)
    }

    public var canLoadMore: Bool { days < CalendarEventQuery.maximumDays }

    public mutating func loadMore() -> Bool {
        guard canLoadMore else { return false }
        days = min(days + CalendarEventQuery.pageDays, CalendarEventQuery.maximumDays)
        return true
    }

    public func query(now: Date = Date(), calendar: Calendar = .current) -> CalendarEventQuery {
        CalendarEventQuery(days: days, now: now, calendar: calendar)
    }
}
