import EventKit
import Foundation
import Testing

@testable import CalendarExtension

@MainActor @Suite struct CalendarInstantSnapshotTests {
    private let empty = Data("{}".utf8)

    private func cachedEvent() -> CalendarEventPayload {
        CalendarEventPayload(
            id: "cached", title: "Synthetic cached event", start: Date(),
            end: Date().addingTimeInterval(600), isAllDay: false)
    }

    @Test func recurringCachedEventsKeepDistinctIdentitiesAndRender() async throws {
        let first = cachedEvent()
        var second = first
        second.start = first.start.addingTimeInterval(86400)
        second.end = first.end.addingTimeInterval(86400)
        let store = CalendarStore(
            snapshotStore: CalendarAgendaSnapshotStore(events: [first, second, first]),
            fetch: { _ in [] }, authorization: { .fullAccess })
        defer { store.shutdown() }
        await store.restoreCachedAgenda()
        #expect(store.events.count == 2)
        #expect(Set(store.events.map(\.id)).count == 2)
        #expect(
            store.events[0].id
                == CalendarEventPayload.occurrenceID(
                    identifier: first.id, calendarID: first.calendarID, start: first.start))
        let snapshot = CalendarUISnapshot(
            authorized: true, blurEvents: true, days: 14, events: store.events)
        let facade = CalendarUIFacade(invoke: { _, _ in try JSONEncoder().encode(snapshot) })
        defer { facade.shutdown() }
        await facade.refreshAndWait()
        #expect(facade.loaded && facade.error == nil && facade.events.count == 2)
    }

    @Test func metadataAnswersFromTheSavedAgendaWhileTheRefreshIsBlocked() async throws {
        let gate = CalendarFetchGate()
        let store = CalendarStore(
            snapshotStore: CalendarAgendaSnapshotStore(events: [cachedEvent()]),
            fetch: { _ in await gate.wait() }, authorization: { .fullAccess })
        let presentation = CalendarPresentationState(channel: nil)
        let engine = CalendarUIEngine(store: store, presentation: presentation)
        defer { gate.release(); engine.shutdown(); store.shutdown(); presentation.shutdown() }
        store.start()
        let reply = try await engine.execute("calendar.ui.metadata", payload: empty)
        let snapshot = try JSONDecoder().decode(CalendarUISnapshot.self, from: reply)
        #expect(snapshot.authorized && snapshot.ready)
        #expect(snapshot.events.map(\.id) == ["cached"])
    }

    @Test func aSavedEmptyAgendaIsReadyWhileTheRefreshIsBlocked() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agenda.json")
        await CalendarAgendaSnapshotStore(file: file).save([])
        let gate = CalendarFetchGate()
        let store = CalendarStore(
            snapshotStore: CalendarAgendaSnapshotStore(file: file),
            fetch: { _ in await gate.wait() }, authorization: { .fullAccess })
        let presentation = CalendarPresentationState(channel: nil)
        let engine = CalendarUIEngine(store: store, presentation: presentation)
        defer { gate.release(); engine.shutdown(); store.shutdown(); presentation.shutdown() }
        store.start()
        let reply = try await engine.execute("calendar.ui.metadata", payload: empty)
        let snapshot = try JSONDecoder().decode(CalendarUISnapshot.self, from: reply)
        #expect(snapshot.ready && snapshot.events.isEmpty)
    }

    @Test func withoutAnySavedAgendaTheSnapshotIsNotReady() async throws {
        let gate = CalendarFetchGate()
        let store = CalendarStore(
            snapshotStore: CalendarAgendaSnapshotStore(events: []),
            fetch: { _ in await gate.wait() }, authorization: { .fullAccess })
        let presentation = CalendarPresentationState(channel: nil)
        let engine = CalendarUIEngine(store: store, presentation: presentation)
        defer { gate.release(); engine.shutdown(); store.shutdown(); presentation.shutdown() }
        store.start()
        let reply = try await engine.execute("calendar.ui.metadata", payload: empty)
        #expect(try JSONDecoder().decode(CalendarUISnapshot.self, from: reply).ready == false)
    }

    @Test func aSecondFacadeStartsWithTheLastKnownAgenda() async throws {
        let memory = CalendarUISnapshotMemory()
        let snapshot = CalendarUISnapshot(
            authorized: true, blurEvents: false, days: 14, events: [cachedEvent()])
        let first = CalendarUIFacade(
            invoke: { _, _ in try JSONEncoder().encode(snapshot) }, memory: memory)
        defer { first.shutdown() }
        await first.refreshAndWait()
        let second = CalendarUIFacade(
            invoke: { _, _ in throw CancellationError() }, memory: memory)
        defer { second.shutdown() }
        #expect(second.loaded && second.events.map(\.id) == ["cached"] && second.authorized)
    }

    @Test func aCancelledRequestNeverSurfacesAsAnError() async throws {
        for failure in [
            CancellationError() as Error, URLError(.cancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        ] {
            let facade = CalendarUIFacade(
                invoke: { _, _ in throw failure },
                navigation: CalendarNavigationRequest(presentationID: UUID(), location: "notch"))
            defer { facade.shutdown() }
            await facade.refreshAndWait()
            await facade.performAndWait(.open)
            await facade.openPageAndWait()
            #expect(facade.error == nil)
        }
    }

    @Test func otherFailuresStillSurface() async throws {
        let facade = CalendarUIFacade(invoke: { _, _ in throw URLError(.notConnectedToInternet) })
        defer { facade.shutdown() }
        await facade.refreshAndWait()
        #expect(facade.error != nil)
    }
}

@MainActor
private final class CalendarFetchGate: @unchecked Sendable {
    private var continuations: [CheckedContinuation<[CalendarEventPayload]?, Never>] = []
    private var released = false

    nonisolated func wait() async -> [CalendarEventPayload]? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                if released {
                    continuation.resume(returning: nil)
                } else {
                    continuations.append(continuation)
                }
            }
        }
    }

    func release() {
        released = true
        for continuation in continuations { continuation.resume(returning: nil) }
        continuations = []
    }
}
