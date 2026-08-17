import Foundation
import Testing
@testable import EdithKit

@Suite struct CalendarDayEventsTests {
    private static func event(
        title: String, start: Date, allDay: Bool = false
    ) -> CalendarEventPayload {
        CalendarEventPayload(
            title: title,
            start: start,
            end: start.addingTimeInterval(1800),
            isAllDay: allDay)
    }

    @Test func sortsAllDayFirstThenByStartTime() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Self.event(title: "Later", start: base.addingTimeInterval(3600))
        let earlier = Self.event(title: "Earlier", start: base)
        let holiday = Self.event(
            title: "Holiday", start: base.addingTimeInterval(-3600), allDay: true)

        let sorted = CalendarDayEvents.sorted([later, earlier, holiday])

        #expect(sorted.map(\.title) == ["Holiday", "Earlier", "Later"])
    }

    @Test func stableWhenAlreadySorted() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Self.event(title: "First", start: base)
        let second = Self.event(title: "Second", start: base.addingTimeInterval(1800))

        let sorted = CalendarDayEvents.sorted([first, second])

        #expect(sorted.map(\.title) == ["First", "Second"])
    }

    @Test func removesMatchingEventsAcrossCalendars() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Self.event(title: "Daily Standup", start: start)
        var duplicate = Self.event(title: "Daily Standup", start: start)
        duplicate.location = "Synced from another account"

        let deduplicated = CalendarDayEvents.deduplicated([first, duplicate])

        #expect(deduplicated.count == 1)
        #expect(deduplicated.first?.id == first.id)
    }

    @Test func removesEventsWithInvisibleProviderDifferences() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Self.event(title: "Daily Standup", start: start)
        var duplicate = Self.event(
            title: "  Daily\nStandup  ", start: start.addingTimeInterval(20))
        duplicate.end = first.end.addingTimeInterval(20)

        let deduplicated = CalendarDayEvents.deduplicated([first, duplicate])

        #expect(deduplicated.count == 1)
        #expect(deduplicated.first?.id == first.id)
    }

    @Test func removesMatchingAllDayEventsWithDifferentStoredDurations() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        var first = Self.event(title: "Holiday", start: start, allDay: true)
        var duplicate = Self.event(title: "Holiday", start: start, allDay: true)
        first.end = calendar.date(byAdding: .day, value: 1, to: start)!
        duplicate.end = calendar.date(byAdding: .day, value: 2, to: start)!

        let deduplicated = CalendarDayEvents.deduplicated(
            [first, duplicate], calendar: calendar)

        #expect(deduplicated.count == 1)
    }

    @Test func retainsEventsWhenIdentityFieldsDiffer() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = Self.event(title: "Daily Standup", start: start)
        let differentTitle = Self.event(title: "Team Standup", start: start)
        let differentStart = Self.event(
            title: "Daily Standup", start: start.addingTimeInterval(60))
        var differentEnd = Self.event(title: "Daily Standup", start: start)
        differentEnd.end = start.addingTimeInterval(3600)
        let allDay = Self.event(title: "Daily Standup", start: start, allDay: true)

        let deduplicated = CalendarDayEvents.deduplicated([
            original, differentTitle, differentStart, differentEnd, allDay,
        ])

        #expect(deduplicated.count == 5)
    }

    @Test func groupsByDayAscendingSortedWithin() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let day1 = day0.addingTimeInterval(86_400)

        let d0Late = Self.event(title: "d0-late", start: day0.addingTimeInterval(7200))
        let d0Early = Self.event(title: "d0-early", start: day0.addingTimeInterval(3600))
        let d1 = Self.event(title: "d1", start: day1.addingTimeInterval(3600))

        let groups = CalendarDayEvents.groupedByDay([d1, d0Late, d0Early], calendar: calendar)

        #expect(groups.count == 2)
        #expect(groups[0].events.map(\.title) == ["d0-early", "d0-late"])
        #expect(groups[1].events.map(\.title) == ["d1"])
    }

    @Test func groupsMatchingEventsOnce() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Self.event(title: "Holiday", start: start, allDay: true)
        let duplicate = Self.event(title: "Holiday", start: start, allDay: true)

        let groups = CalendarDayEvents.groupedByDay([first, duplicate])

        #expect(groups.count == 1)
        #expect(groups[0].events.count == 1)
    }
}

@Suite struct CalendarTextTests {
    private static func event(
        minutes: Int, allDay: Bool = false
    ) -> CalendarEventPayload {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return CalendarEventPayload(
            title: "Event",
            start: start,
            end: start.addingTimeInterval(TimeInterval(minutes * 60)),
            isAllDay: allDay)
    }

    @Test func formatsUsefulDurations() {
        #expect(CalendarText.duration(for: Self.event(minutes: 30)) == "30 min")
        #expect(CalendarText.duration(for: Self.event(minutes: 60)) == "1 hr")
        #expect(CalendarText.duration(for: Self.event(minutes: 150)) == "2 hr 30 min")
    }

    @Test func labelsAllDayEventsWithoutSecondaryTime() {
        let event = Self.event(minutes: 1_440, allDay: true)

        #expect(CalendarText.startTime(for: event) == "All day")
        #expect(CalendarText.timeDetail(for: event) == nil)
    }

    @Test func summarizesParticipantResponses() {
        var event = Self.event(minutes: 30)
        event.attendees = [
            Self.participant(status: "accepted"),
            Self.participant(status: "accepted"),
            Self.participant(status: "pending"),
            Self.participant(status: "declined"),
        ]

        #expect(CalendarText.responseSummary(for: event) == "2 accepted · 1 pending · 1 declined")
    }

    @Test func limitsAttendeeNames() {
        var event = Self.event(minutes: 30)
        event.attendees = (1...8).map {
            Self.participant(name: "Person \($0)", status: "pending")
        }

        #expect(
            CalendarText.attendeeNames(for: event)
                == "Person 1, Person 2, Person 3, Person 4, Person 5, Person 6 +2 more")
    }

    private static func participant(
        name: String? = nil, status: String
    ) -> CalendarParticipantPayload {
        CalendarParticipantPayload(
            name: name,
            address: nil,
            status: status,
            role: "required",
            isCurrentUser: false)
    }
}

@Suite struct CalendarEventActionsTests {
    private static func event(
        location: String? = nil, latitude: Double? = nil, longitude: Double? = nil
    ) -> CalendarEventPayload {
        CalendarEventPayload(
            title: "Planning",
            start: Date(timeIntervalSinceReferenceDate: 123_456),
            end: Date(timeIntervalSinceReferenceDate: 127_056),
            isAllDay: false,
            location: location,
            latitude: latitude,
            longitude: longitude)
    }

    @Test func targetsCalendarApplication() {
        #expect(CalendarEventActions.calendarApplicationURL.lastPathComponent == "Calendar.app")
        #expect(CalendarEventActions.calendarApplicationURL.isFileURL)
    }

    @Test func createsMapsLinkWithCoordinates() {
        let url = CalendarEventActions.locationURL(
            for: Self.event(location: "Conference Room", latitude: 12.9, longitude: 77.6))
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let query = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            })

        #expect(components?.host == "maps.apple.com")
        #expect(query["q"] == "Conference Room")
        #expect(query["ll"] == "12.9,77.6")
    }

    @Test func omitsDirectionsWithoutLocation() {
        #expect(CalendarEventActions.locationURL(for: Self.event()) == nil)
        #expect(CalendarEventActions.locationURL(for: Self.event(location: "   ")) == nil)
    }
}

@Suite struct CalendarEventPayloadTests {
    @Test func roundTripsExtendedEventData() {
        let participant = CalendarParticipantPayload(
            name: "Taylor",
            address: "mailto:taylor@example.com",
            status: "accepted",
            role: "required",
            isCurrentUser: false)
        let event = CalendarEventPayload(
            id: "event-1",
            title: "Planning",
            calendar: "Work",
            calendarColor: CalendarColorPayload(red: 1, green: 0.5, blue: 0, alpha: 1),
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600),
            isAllDay: false,
            location: "Conference Room",
            latitude: 12.9,
            longitude: 77.6,
            meetingURL: "https://meet.google.com/abc-defg-hij",
            url: "https://example.com/event",
            notes: "Review the proposal",
            organizer: participant,
            attendees: [participant],
            isRecurring: true,
            status: "confirmed",
            availability: "busy",
            timeZone: "Asia/Kolkata",
            hasAlarms: true)

        let decoded = CalendarEventBridge.decode(CalendarEventBridge.encode([event]))

        #expect(decoded == [event])
    }
}

@Suite struct MeetingLinkTests {
    @Test func findsZoomLinkInNotes() {
        let notes = "Join Zoom Meeting\nhttps://us02web.zoom.us/j/8412345678?pwd=abc\nID: 841"
        #expect(MeetingLink.find(in: notes)?.host == "us02web.zoom.us")
    }

    @Test func findsGoogleMeet() {
        let url = MeetingLink.find(in: "video call: https://meet.google.com/abc-defg-hij")
        #expect(url?.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test func ignoresNonMeetingLinks() {
        #expect(MeetingLink.find(in: "Directions https://maps.google.com/?q=cafe") == nil)
    }

    @Test func lookalikeHostRejected() {
        #expect(MeetingLink.find(in: "https://zoom.us.phishy.example/j/1") == nil)
    }

    @Test func plainTextHasNoLink() {
        #expect(MeetingLink.find(in: "Lunch with the team") == nil)
    }

    @Test func matchesBareHostWithoutSubdomain() {
        #expect(MeetingLink.find(in: "https://zoom.us/j/1234567890")?.host == "zoom.us")
    }

    @Test func findsTeamsLink() {
        #expect(MeetingLink.find(in: "https://teams.microsoft.com/l/meetup-join/xyz") != nil)
    }

    @Test func picksMeetingLinkAmongOtherLinks() {
        let text = "Agenda: https://example.com/doc\nJoin: https://meet.google.com/abc-defg-hij"
        #expect(MeetingLink.find(in: text)?.host == "meet.google.com")
    }

    @Test func emptyTextYieldsNothing() {
        #expect(MeetingLink.find(in: "") == nil)
    }
}
