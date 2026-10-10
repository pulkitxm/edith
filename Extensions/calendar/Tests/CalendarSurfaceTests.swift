import EdithExtensionSupport
import Foundation
import Testing

@testable import CalendarExtension

@MainActor @Suite struct CalendarSurfaceTests {
    @Test func projectionUsesStableCalendarIDsLimitsAndConfiguredFields() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = await fixture.store.refreshAndWait()
        var tile = SurfaceTile(.calendar)
        tile.sourceIDs = ["calendar-one"]
        tile.itemLimit = 1
        tile.hiddenFields = ["time", "join"]
        let snapshot = fixture.surface.snapshot(tile)
        #expect(snapshot.rows.map(\.title) == ["Synthetic meeting one"])
        #expect(snapshot.rows.first?.value == "")
        #expect(snapshot.rows.first?.actions.isEmpty == true)
        #expect(Set(snapshot.sources.map(\.id)) == ["calendar-one", "calendar-two"])
        #expect(try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "calendar") == snapshot)
        tile.sourceIDs = []
        #expect(fixture.surface.snapshot(tile).rows.isEmpty)
    }

    @Test func homePreservesTheEntireTodayScheduleAndTimeRangesWhileNotchShowsUpcoming()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let channel = ExtensionSharedState(root: root, namespace: "fixture", owner: "presenter")
        let presentation = CalendarPresentationState(channel: channel)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let now = calendar.date(byAdding: .hour, value: 12, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let events = [
            CalendarEventPayload(
                id: "past-today", title: "Finished synthetic meeting", calendar: "Synthetic",
                calendarID: "one", start: today.addingTimeInterval(3600),
                end: today.addingTimeInterval(7200), isAllDay: false),
            CalendarEventPayload(
                id: "next-today", title: "Upcoming synthetic meeting", calendar: "Synthetic",
                calendarID: "one", start: now.addingTimeInterval(3600),
                end: now.addingTimeInterval(7200), isAllDay: false),
            CalendarEventPayload(
                id: "tomorrow", title: "Tomorrow synthetic meeting", calendar: "Synthetic",
                calendarID: "one", start: tomorrow.addingTimeInterval(3600),
                end: tomorrow.addingTimeInterval(7200), isAllDay: false),
            CalendarEventPayload(
                id: "all-day", title: "Synthetic all-day event", calendar: "Synthetic",
                calendarID: "two", start: today, end: tomorrow, isAllDay: true),
        ]
        let store = CalendarStore(
            snapshotStore: .init(file: root.appendingPathComponent("agenda.json")),
            fetch: { _ in events })
        defer {
            store.shutdown(); presentation.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        _ = await store.refreshAndWait()
        let surface = CalendarSurface(
            store: store, presentation: presentation, authorized: { true })
        var tile = SurfaceTile(.calendar)
        tile.itemLimit = 20
        let home = surface.snapshot(tile, target: .home, now: now)
        #expect(Set(home.rows.map(\.id)) == ["past-today", "next-today", "all-day"])
        let past = events.first { $0.id == "past-today" }!
        #expect(
            home.rows.first { $0.id == "past-today" }?.value == past.start.formatted(
                date: .omitted, time: .shortened) + "–"
                + past.end.formatted(date: .omitted, time: .shortened))
        #expect(home.rows.first { $0.id == "all-day" }?.value == "All day")
        #expect(
            Set(surface.snapshot(tile, target: .notch, now: now).rows.map(\.id)) == [
                "next-today", "tomorrow", "all-day",
            ])
        let next = events.first { $0.id == "next-today" }!
        #expect(
            surface.snapshot(tile, target: .notch, now: now).rows.first {
                $0.id == "next-today"
            }?.value == next.start.formatted(date: .omitted, time: .shortened))
        tile.sourceIDs = ["one"]
        #expect(
            Set(surface.snapshot(tile, target: .home, now: now).rows.map(\.id)) == [
                "past-today", "next-today",
            ])
        tile.hiddenFields = ["time"]
        #expect(
            surface.snapshot(tile, target: .home, now: now).rows.allSatisfy { $0.value.isEmpty })
    }

    @Test func unauthorizedCachedDataNeverReachesHomeOrNotch() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = await fixture.store.refreshAndWait()
        let surface = CalendarSurface(
            store: fixture.store, presentation: fixture.presentation, authorized: { false })
        let snapshot = surface.snapshot(.init(.calendar))
        #expect(snapshot.rows.isEmpty && snapshot.sources.isEmpty)
        #expect(snapshot.message == "Open Calendar to grant access to your meetings.")
    }

    @Test func presenterMasksPrivateCalendarDataBeforeCrossingTheWorkerBoundary() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = await fixture.store.refreshAndWait()
        try fixture.channel.publish(["active": "1", "blurCalendar": "1"])
        fixture.presentation.refresh()
        let snapshot = fixture.surface.snapshot(.init(.calendar))
        #expect(
            snapshot.rows.allSatisfy {
                $0.title == "Meeting" && $0.detail.isEmpty && $0.sourceID == "hidden"
            })
        #expect(snapshot.sources.isEmpty)
        let text = String(decoding: try snapshot.encoded(), as: UTF8.self)
        #expect(!text.contains("Synthetic meeting") && !text.contains("Synthetic calendar"))
    }

    @Test func aMeetingActionResolvesTheCurrentWorkerRecordAndNeverAcceptsAURLPayload() async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = await fixture.store.refreshAndWait()
        let tile = SurfaceTile(.calendar)
        let snapshot = SurfaceSnapshotRequest(target: .home, tile: tile)
        let action = SurfaceActionRequest(snapshot: snapshot, actionID: "join:meeting-one")
        _ = try await fixture.surface.execute(
            "surface.perform", payload: action.encoded(providerID: "calendar"))
        #expect(fixture.opened.urls == [URL(string: "https://meet.google.com/synthetic-meeting")!])
        let invalid = SurfaceActionRequest(
            snapshot: snapshot, actionID: "https://example.invalid/other")
        await #expect(throws: (any Error).self) {
            try await fixture.surface.execute(
                "surface.perform", payload: invalid.encoded(providerID: "calendar"))
        }
        #expect(fixture.opened.urls.count == 1)
    }

    @Test func hiddenJoinControlsAndUnselectedCalendarsRejectOldActions() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = await fixture.store.refreshAndWait()
        for mode in ["field", "actions", "selection"] {
            var tile = SurfaceTile(.calendar)
            if mode == "field" { tile.hiddenFields = ["join"] }
            if mode == "actions" { tile.showActions = false }
            if mode == "selection" { tile.sourceIDs = ["calendar-two"] }
            let action = SurfaceActionRequest(
                snapshot: .init(target: .home, tile: tile), actionID: "join:meeting-one")
            await #expect(throws: (any Error).self) {
                try await fixture.surface.execute(
                    "surface.perform", payload: action.encoded(providerID: "calendar"))
            }
        }
        #expect(fixture.opened.urls.isEmpty)
    }

    @MainActor private final class Opened { var urls: [URL] = [] }

    @MainActor private struct Fixture {
        let root: URL
        let channel: ExtensionSharedState
        let store: CalendarStore
        let presentation: CalendarPresentationState
        let surface: CalendarSurface
        let opened = Opened()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            channel = ExtensionSharedState(root: root, namespace: "fixture", owner: "presenter")
            presentation = CalendarPresentationState(channel: channel)
            let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(43_200)
            let events = [
                CalendarEventPayload(
                    id: "meeting-one", title: "Synthetic meeting one",
                    calendar: "Synthetic calendar", calendarID: "calendar-one",
                    start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800),
                    isAllDay: false, meetingURL: "https://meet.google.com/synthetic-meeting"),
                CalendarEventPayload(
                    id: "meeting-two", title: "Synthetic meeting two",
                    calendar: "Synthetic calendar", calendarID: "calendar-two",
                    start: now.addingTimeInterval(900), end: now.addingTimeInterval(2100),
                    isAllDay: false),
                CalendarEventPayload(
                    id: "expired", title: "Past synthetic meeting", calendar: "Synthetic calendar",
                    calendarID: "calendar-one",
                    start: Calendar.current.date(byAdding: .day, value: -1, to: now)!,
                    end: Calendar.current.date(byAdding: .day, value: -1, to: now)!
                        .addingTimeInterval(600), isAllDay: false),
            ]
            store = CalendarStore(
                snapshotStore: .init(file: root.appendingPathComponent("agenda.json")),
                fetch: { _ in events })
            surface = CalendarSurface(
                store: store, presentation: presentation,
                open: { [opened] url in
                    opened.urls.append(url); return true
                }, authorized: { true })
        }

        func clean() {
            store.shutdown(); presentation.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
