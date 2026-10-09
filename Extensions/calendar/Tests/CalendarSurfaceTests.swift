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
            let now = Date()
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
                    calendarID: "calendar-one", start: now.addingTimeInterval(-1800),
                    end: now.addingTimeInterval(-600), isAllDay: false),
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
