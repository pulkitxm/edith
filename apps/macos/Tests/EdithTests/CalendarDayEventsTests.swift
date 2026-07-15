import Testing
import EventKit
@testable import EdithKit

@Suite struct CalendarDayEventsTests {
    private static let scratchStore = EKEventStore()

    private static func event(title: String, start: Date, allDay: Bool = false) -> EKEvent {
        let event = EKEvent(eventStore: scratchStore)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(1800)
        event.isAllDay = allDay
        return event
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
        let duplicate = Self.event(title: "Daily Standup", start: start)
        duplicate.location = "Synced from another account"

        let deduplicated = CalendarDayEvents.deduplicated([first, duplicate])

        #expect(deduplicated.count == 1)
        #expect(deduplicated.first === first)
    }

    @Test func retainsEventsWhenIdentityFieldsDiffer() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = Self.event(title: "Daily Standup", start: start)
        let differentTitle = Self.event(title: "Team Standup", start: start)
        let differentStart = Self.event(
            title: "Daily Standup", start: start.addingTimeInterval(60))
        let differentEnd = Self.event(title: "Daily Standup", start: start)
        differentEnd.endDate = start.addingTimeInterval(3600)
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
