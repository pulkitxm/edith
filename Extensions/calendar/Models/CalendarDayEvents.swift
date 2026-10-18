import EventKit
import Foundation

public enum CalendarDayEvents {
    private struct EventIdentity: Hashable {
        let title: String
        let startMinute: Int64
        let endMinute: Int64?
        let isAllDay: Bool

        init(event: CalendarEventPayload, calendar: Calendar) {
            title =
                event.title
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .precomposedStringWithCanonicalMapping
            isAllDay = event.isAllDay
            if event.isAllDay {
                startMinute = Self.minute(calendar.startOfDay(for: event.start))
                endMinute = nil
            } else {
                startMinute = Self.minute(event.start)
                endMinute = Self.minute(event.end)
            }
        }

        private static func minute(_ date: Date) -> Int64 {
            Int64(floor(date.timeIntervalSinceReferenceDate / 60))
        }
    }

    public static func deduplicated(
        _ events: [CalendarEventPayload], calendar: Calendar = .current
    ) -> [CalendarEventPayload] {
        var identities = Set<EventIdentity>()
        return events.filter { event in
            identities.insert(EventIdentity(event: event, calendar: calendar)).inserted
        }
    }

    public static func sorted(_ events: [CalendarEventPayload]) -> [CalendarEventPayload] {
        events.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            return a.start < b.start
        }
    }

    public static func groupedByDay(
        _ events: [CalendarEventPayload], calendar: Calendar = .current
    ) -> [(day: Date, events: [CalendarEventPayload])] {
        let byDay = Dictionary(grouping: sorted(deduplicated(events, calendar: calendar))) {
            calendar.startOfDay(for: $0.start)
        }
        return byDay.keys.sorted().map { (day: $0, events: byDay[$0]!) }
    }
}

public enum MeetingLink {
    private static let hosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "chime.aws",
        "gotomeeting.com", "bluejeans.com", "8x8.vc",
    ]

    public static func url(for event: CalendarEventPayload) -> URL? {
        event.meetingURL.flatMap(URL.init(string:))
    }

    static func url(for event: EKEvent) -> URL? {
        if let url = event.url, isMeeting(url) { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        return find(in: text)
    }

    public static func find(in text: String) -> URL? {
        guard !text.isEmpty,
            let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, isMeeting(url) { return url }
        }
        return nil
    }

    private static func isMeeting(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
