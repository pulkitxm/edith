import EdithExtensionSupport
import Foundation
import Testing

@testable import CalendarExtension

@MainActor @Suite struct CalendarUIEngineTests {
    @Test func actionsResolveOwnedEventsAndRejectURLInjection() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        _ = try await fixture.engine.execute("calendar.ui.list", payload: Data("{}".utf8))
        for action in [CalendarUIAction.join, .directions] {
            _ = try await fixture.engine.execute(
                "calendar.ui.action",
                payload: JSONEncoder().encode(
                    CalendarUIActionRequest(action: action, eventID: "one")))
        }
        #expect(fixture.opened.count == 2)
        #expect(fixture.opened[0].absoluteString == "https://meet.google.com/synthetic")
        #expect(fixture.opened[1].host == "maps.apple.com")
        for payload in [
            "{\"action\":\"join\",\"eventID\":\"one\",\"url\":\"https://example.invalid\"}",
            "{\"action\":\"join\",\"eventID\":\"missing\"}",
            "{\"action\":\"open\",\"eventID\":\"one\"}",
        ] {
            await #expect(throws: (any Error).self) {
                try await fixture.engine.execute("calendar.ui.action", payload: Data(payload.utf8))
            }
        }
        fixture.allowed = false
        await #expect(throws: (any Error).self) {
            try await fixture.engine.execute(
                "calendar.ui.action",
                payload: Data("{\"action\":\"join\",\"eventID\":\"one\"}".utf8))
        }
        #expect(fixture.opened.count == 2)
    }

    @Test func privacyAndPermissionAreAppliedBeforeAnyEventIsReturned() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        _ = try await fixture.engine.execute("calendar.ui.list", payload: Data("{}".utf8))
        try fixture.channel.publish(["active": "1", "blurCalendar": "1"])
        let data = try await fixture.engine.execute(
            "calendar.ui.metadata", payload: Data("{}".utf8))
        let snapshot = try JSONDecoder().decode(CalendarUISnapshot.self, from: data)
        #expect(snapshot.blurEvents && snapshot.events.first?.title == "Meeting")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("Synthetic private") && !text.contains("google.com/synthetic"))
        fixture.allowed = false
        let denied = try await fixture.engine.execute("calendar.ui.list", payload: Data("{}".utf8))
        #expect(try JSONDecoder().decode(CalendarUISnapshot.self, from: denied).events.isEmpty)
        _ = try await fixture.engine.execute(
            "calendar.ui.action", payload: Data("{\"action\":\"permission\"}".utf8))
        #expect(fixture.grants == 1)
        fixture.engine.shutdown()
        await #expect(throws: (any Error).self) {
            try await fixture.engine.execute("calendar.ui.list", payload: Data("{}".utf8))
        }
    }

    @Test func paginationIsBoundedAndRecordsKeepTheirOriginalDetails() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        let data = try await fixture.engine.execute("calendar.ui.list", payload: Data("{}".utf8))
        let snapshot = try JSONDecoder().decode(CalendarUISnapshot.self, from: data)
        #expect(snapshot.events.first?.notes == "Synthetic private notes")
        #expect(snapshot.days == 14)
        for _ in 0..<12 {
            _ = try await fixture.engine.execute("calendar.ui.loadMore", payload: Data("{}".utf8))
        }
        #expect(fixture.engine.snapshot().days == 120)
        #expect(fixture.engine.snapshot().events.count == 1)
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let channel: ExtensionSharedState
        let store: CalendarStore
        let presentation: CalendarPresentationState
        var allowed = true
        var grants = 0
        var opened: [URL] = []
        lazy var engine = CalendarUIEngine(
            store: store, presentation: presentation, authorized: { [unowned self] in allowed },
            open: { [unowned self] in
                opened.append($0); return true
            },
            grant: { [unowned self] in grants += 1 })

        init() {
            channel = ExtensionSharedState(root: root, namespace: "fixture", owner: "presenter")
            presentation = CalendarPresentationState(channel: channel)
            let now = Date()
            let event = CalendarEventPayload(
                id: "one", title: "Synthetic private title", calendar: "Synthetic private calendar",
                calendarID: "one", start: now, end: now.addingTimeInterval(600), isAllDay: false,
                location: "Synthetic private hall", meetingURL: "https://meet.google.com/synthetic",
                notes: "Synthetic private notes")
            store = CalendarStore(
                snapshotStore: .init(file: root.appendingPathComponent("agenda.json")),
                fetch: { _ in [event] })
        }

        func stop() {
            engine.shutdown(); store.shutdown(); presentation.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
