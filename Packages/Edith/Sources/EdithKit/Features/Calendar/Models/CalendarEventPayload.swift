import EventKit
import Foundation

public struct CalendarEventPayload: Codable, Equatable, Sendable {
    public var title: String
    public var calendar: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var meetingURL: String?

    public init(
        title: String, calendar: String, start: Date, end: Date, isAllDay: Bool,
        location: String? = nil, meetingURL: String? = nil
    ) {
        self.title = title
        self.calendar = calendar
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.meetingURL = meetingURL
    }
}

public enum CalendarEventBridge {
    public static let payloadKey = "events"
    public static let statusKey = "status"

    public static func payloads(_ events: [EKEvent]) -> [CalendarEventPayload] {
        CalendarDayEvents.sorted(CalendarDayEvents.deduplicated(events)).map { event in
            CalendarEventPayload(
                title: event.title ?? "Untitled",
                calendar: event.calendar?.title ?? "",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location,
                meetingURL: MeetingLink.url(for: event)?.absoluteString)
        }
    }

    public static func encode(_ payloads: [CalendarEventPayload]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payloads) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> [CalendarEventPayload] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = text.data(using: .utf8),
            let payloads = try? decoder.decode([CalendarEventPayload].self, from: data)
        else { return [] }
        return payloads
    }
}
