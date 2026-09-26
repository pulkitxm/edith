import Foundation
import Testing

@testable import EdithKit

@Suite struct ClipboardTimelineTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(
        _ preview: String, hoursAgo: Double, pinned: Bool = false, source: String? = "Notes"
    ) -> ClipboardEntry {
        let moment = Self.now.addingTimeInterval(-hoursAgo * 3600)
        return ClipboardEntry(
            id: preview, sha256: preview, types: ["public.utf8-plain-text"], ext: "txt",
            sourceApp: source, sourceBundleID: nil, createdAt: moment, size: 1,
            preview: preview, pinned: pinned)
    }

    private func sections(_ entries: [ClipboardEntry], pinToTop: Bool = true)
        -> [ClipboardSection]
    {
        ClipboardTimeline.sections(
            ClipboardActions.arrange(entries, pinToTop: pinToTop), now: Self.now,
            calendar: Self.calendar)
    }

    @Test func groupsHistoryIntoPinnedTodayYesterdayAndOlderDays() {
        let hour = Self.calendar.component(.hour, from: Self.now)
        let result = sections([
            entry("pin", hoursAgo: 200, pinned: true),
            entry("now", hoursAgo: 0),
            entry("earlier", hoursAgo: Double(hour) - 0.5),
            entry("yesterday", hoursAgo: Double(hour) + 1),
            entry("three days", hoursAgo: Double(hour) + 49),
            entry("last month", hoursAgo: 24 * 40),
            entry("last year", hoursAgo: 24 * 400),
        ])

        #expect(
            result.map(\.title) == [
                "Pinned", "Today", "Yesterday", "Friday", "August 12", "August 17, 2025",
            ])
        #expect(
            result.map { $0.entries.map(\.id) } == [
                ["pin"], ["now", "earlier"], ["yesterday"], ["three days"], ["last month"],
                ["last year"],
            ])
        #expect(Set(result.map(\.id)).count == result.count)
    }

    @Test func pinnedSectionFollowsThePinToBottomPreference() {
        let result = sections(
            [entry("pin", hoursAgo: 1, pinned: true), entry("loose", hoursAgo: 2)],
            pinToTop: false)

        #expect(result.map(\.title) == ["Today", "Pinned"])
    }

    @Test func flattenedSectionsKeepTheArrangedOrder() {
        let entries =
            (0..<60).map { entry("item \($0)", hoursAgo: Double($0) * 7) }
            + [entry("pinned", hoursAgo: 3, pinned: true)]
        let arranged = ClipboardActions.arrange(entries)
        let flattened = ClipboardTimeline.sections(arranged, now: Self.now, calendar: Self.calendar)
            .flatMap(\.entries)

        #expect(flattened == arranged)
    }

    @Test func futureTimestampsCountAsToday() {
        let result = sections([entry("skewed", hoursAgo: -30)])

        #expect(result.map(\.title) == ["Today"])
    }

    @Test func nonContiguousInputStillProducesUniqueSectionIDs() {
        let today = entry("a", hoursAgo: 0)
        let older = entry("b", hoursAgo: 72)
        let again = entry("c", hoursAgo: 0)
        let result = ClipboardTimeline.sections(
            [today, older, again], now: Self.now, calendar: Self.calendar)

        #expect(result.count == 3)
        #expect(Set(result.map(\.id)).count == 3)
    }

    @Test func emptyHistoryHasNoSections() {
        #expect(ClipboardTimeline.sections([], now: Self.now, calendar: Self.calendar).isEmpty)
    }

    @Test func olderPinnedClipsNameTheirDayBecauseTheyLeaveTheDaySections() {
        let old = entry("old pin", hoursAgo: 72, pinned: true)
        let fresh = entry("fresh pin", hoursAgo: 0, pinned: true)
        let loose = entry("loose", hoursAgo: 72)

        let oldLine = ClipboardTimeline.subtitle(for: old, now: Self.now, calendar: Self.calendar)
        #expect(
            oldLine
                == "Notes · "
                + ClipboardTimeline.dayAndTimeLabel(old.lastCopiedAt, calendar: Self.calendar))
        #expect(oldLine.contains("Sep"))
        #expect(
            ClipboardTimeline.subtitle(for: fresh, now: Self.now, calendar: Self.calendar)
                == "Notes · "
                + ClipboardTimeline.timeLabel(fresh.lastCopiedAt, calendar: Self.calendar))
        #expect(
            ClipboardTimeline.subtitle(for: loose, now: Self.now, calendar: Self.calendar)
                == "Notes · "
                + ClipboardTimeline.timeLabel(loose.lastCopiedAt, calendar: Self.calendar))
    }

    @Test func subtitleNamesTheSourceAppAndTime() {
        let clip = entry("x", hoursAgo: 0)
        let time = ClipboardTimeline.timeLabel(clip.lastCopiedAt, calendar: Self.calendar)

        #expect(
            ClipboardTimeline.subtitle(for: clip, now: Self.now, calendar: Self.calendar)
                == "Notes · \(time)")
        #expect(
            ClipboardTimeline.subtitle(
                for: entry("y", hoursAgo: 0, source: nil), calendar: Self.calendar)
                == time)
        #expect(
            ClipboardTimeline.subtitle(
                for: entry("z", hoursAgo: 0, source: "  "), calendar: Self.calendar)
                == time)
        #expect(time.contains(":"))
    }
}
