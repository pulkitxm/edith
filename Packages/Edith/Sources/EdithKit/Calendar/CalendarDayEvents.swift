import EventKit
import Foundation

public enum CalendarDayEvents {
    private struct EventIdentity: Hashable {
        let title: String?
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
    }

    public static func deduplicated(_ events: [EKEvent]) -> [EKEvent] {
        var identities = Set<EventIdentity>()
        return events.filter { event in
            identities.insert(
                EventIdentity(
                    title: event.title,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay
                )
            ).inserted
        }
    }

    public static func sorted(_ events: [EKEvent]) -> [EKEvent] {
        events.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            return a.startDate < b.startDate
        }
    }

    public static func groupedByDay(
        _ events: [EKEvent], calendar: Calendar = .current
    ) -> [(day: Date, events: [EKEvent])] {
        let byDay = Dictionary(grouping: sorted(deduplicated(events))) {
            calendar.startOfDay(for: $0.startDate)
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

    public static func url(for event: EKEvent) -> URL? {
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
