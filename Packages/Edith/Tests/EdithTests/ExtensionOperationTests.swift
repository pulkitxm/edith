import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct ExtensionOperationDescriptorTests {
    @Test func descriptorsAreUniqueAndRegistered() {
        let descriptors =
            CalendarEventOperation.allCases.map(\.descriptor)
            + ShelfItemOperation.allCases.map(\.descriptor)
            + DownloadOperation.allCases.map(\.descriptor)
            + MusicLibraryOperation.allCases.map(\.descriptor)
            + MusicLibraryContentOperation.allCases.map(\.descriptor)
            + MusicFolderSelectionOperation.allCases.map(\.descriptor)
            + MusicTransportOperation.allCases.map(\.descriptor)
            + PresenterRuntimeOperation.allCases.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        #expect(descriptors.allSatisfy { UserOperationCatalog.descriptor(id: $0.id) == $0 })
        #expect(
            Set(descriptors.filter(\.requiresPreview).map(\.id)) == [
                DownloadOperation.remove.descriptor.id,
                DownloadOperation.clear.descriptor.id,
                MusicLibraryContentOperation.remove.descriptor.id,
            ])
    }

    @MainActor
    @Test func calendarAndShelfExecutorsUseOnlyNamedTargets() throws {
        let calendar = URL(string: "https://meet.example/a")!
        var joined: URL?
        #expect(
            CalendarEventOperationExecution.join(
                calendar,
                using: {
                    joined = $0
                    return true
                }))
        #expect(joined == calendar)

        let event = CalendarEventPayload(
            id: "visit", title: "Visit", start: .now, end: .now, isAllDay: false,
            location: "1 Infinite Loop", latitude: 37.3317, longitude: -122.0301)
        var directions: URL?
        let routed = try #require(
            CalendarEventOperationExecution.directions(
                event,
                using: {
                    directions = $0
                    return true
                }))
        #expect(routed.opened)
        #expect(routed.url == directions)
        #expect(routed.url.host == "maps.apple.com")

        let first = URL(fileURLWithPath: "/tmp/first")
        let second = URL(fileURLWithPath: "/tmp/second")
        var revealed: [URL] = []
        #expect(
            ShelfItemOperationExecution.perform(
                .reveal, urls: [first, second], reveal: { revealed = $0 }))
        #expect(revealed == [first, second])
        let id = UUID()
        let decoded = try #require(
            ShelfItemOperationExecution.request(
                ShelfItemOperationExecution.payload(.share, itemIDs: [id])))
        #expect(decoded.operation == .share)
        #expect(decoded.itemIDs == [id])
    }

    @Test func calendarReadUsesTheSharedBoundedQuery() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-23T12:00:00Z"))
        let query = CalendarEventQuery(days: 7, now: now, calendar: calendar)
        let duplicate = CalendarEventPayload(
            id: "first", title: "Planning", start: now, end: now.addingTimeInterval(3600),
            isAllDay: false)
        let copy = CalendarEventPayload(
            id: "second", title: "Planning", start: now, end: now.addingTimeInterval(3600),
            isAllDay: false)
        let late = CalendarEventPayload(
            id: "late", title: "Later", start: query.end.addingTimeInterval(1),
            end: query.end.addingTimeInterval(3600), isAllDay: false)
        var received: CalendarEventQuery?
        let events = await CalendarEventOperationExecution.events(query) { value in
            received = value
            return [late, copy, duplicate]
        }
        #expect(received == query)
        #expect(events.map(\.id) == ["second"])
    }

    @Test func calendarPaginationStopsAtOneHundredTwentyDays() {
        var pagination = CalendarEventPagination()
        var days = [pagination.days]
        while pagination.loadMore() { days.append(pagination.days) }
        #expect(days == [14, 28, 42, 56, 70, 84, 98, 112, 120])
        #expect(!pagination.canLoadMore)
        let loaded = pagination.loadMore()
        #expect(!loaded)
    }

    @Test func calendarQueryRoundTripsTheRequestedWindow() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-23T12:00:00Z"))
        let query = CalendarEventQuery(days: 120, now: now)
        let decoded = CalendarEventBridge.decodeQuery(CalendarEventBridge.encode(query))
        #expect(decoded.days == 120)
        #expect(decoded.start == query.start)
        #expect(decoded.end == query.end)
    }

    @MainActor
    @Test func musicOperationsAreIdempotentAndUseTheResolvedURL() throws {
        var favourite = false
        var writes: [(String, Bool)] = []
        let first = MusicLibraryOperationExecution.setFavourite(
            .favorite, path: "Focus/song.mp3", contains: { _ in favourite },
            set: { path, wanted in
                writes.append((path, wanted))
                favourite = wanted
                return true
            })
        let second = MusicLibraryOperationExecution.setFavourite(
            .favorite, path: "Focus/song.mp3", contains: { _ in favourite },
            set: { _, _ in false })
        #expect(first.changed)
        #expect(!second.changed)
        #expect(writes.count == 1)
        #expect(writes.first?.0 == "Focus/song.mp3")

        let track = URL(fileURLWithPath: "/tmp/song.mp3")
        var revealed: [URL] = []
        #expect(
            MusicLibraryOperationExecution.reveal(track, using: { revealed = $0 }) == track)
        #expect(revealed == [track])
    }

    @Test func presenterRuntimeChangesOnlyWhenEnabled() {
        let suite = "test.presenter.operation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var posted: [Notification.Name] = []
        let disabled = PresenterRuntimeOperationExecution.perform(
            .start, defaults: defaults, post: { posted.append($0) })
        #expect(!disabled.manual)
        #expect(posted.isEmpty)

        defaults.set(true, forKey: AppStorageKeys.Presenter.enabled)
        let started = PresenterRuntimeOperationExecution.perform(
            .start, defaults: defaults, post: { posted.append($0) })
        #expect(started.manual)
        #expect(started.active)
        let stopped = PresenterRuntimeOperationExecution.perform(
            .stop, defaults: defaults, post: { posted.append($0) })
        #expect(!stopped.manual)
        #expect(posted.contains(IPC.Name.presenterPauseAuto))
    }
}

@Suite struct ExtensionOperationCLITests {
    @Test func calendarResolverAcceptsIDsAndRejectsAmbiguousTitles() throws {
        let now = Date()
        let first = CalendarEventPayload(
            id: "first", title: "Planning", start: now, end: now, isAllDay: false,
            meetingURL: "https://meet.example/first")
        let second = CalendarEventPayload(
            id: "second", title: "Planning review", start: now, end: now, isAllDay: false)
        #expect(try CalendarBridge.event("first", in: [first, second]).id == "first")
        #expect(throws: CLIFailure.self) {
            _ = try CalendarBridge.event("Plan", in: [first, second])
        }
    }

    @Test func typedCompletionUsesDomainCandidates() {
        let shelf = CompletionEngine.plan(
            CompletionRequest(words: ["ed", "shelf", "open", ""], index: 3), machines: [],
            configKeys: [], extensionIDs: [], shelfItems: ["1", "2"])
        let music = CompletionEngine.plan(
            CompletionRequest(words: ["ed", "music", "favorite", "F"], index: 3), machines: [],
            configKeys: [], extensionIDs: [], musicTracks: ["Focus/song.mp3"])
        let calendar = CompletionEngine.plan(
            CompletionRequest(words: ["ed", "calendar", "join", "e"], index: 3), machines: [],
            configKeys: [], extensionIDs: [], calendarEvents: ["event-1"])
        let directions = CompletionEngine.plan(
            CompletionRequest(words: ["ed", "calendar", "directions", "e"], index: 3),
            machines: [], configKeys: [], extensionIDs: [], calendarEvents: ["event-1"])
        #expect(shelf.candidates == ["1", "2"])
        #expect(music.candidates == ["Focus/song.mp3"])
        #expect(calendar.candidates == ["event-1"])
        #expect(directions.candidates == ["event-1"])
    }

    @MainActor
    @Test func calendarDirectionsHasStablePlainAndJSONOutput() async throws {
        let now = Date().addingTimeInterval(86400)
        let event = CalendarEventPayload(
            id: "visit", title: "Studio visit", start: now,
            end: now.addingTimeInterval(3600), isAllDay: false,
            location: "1 Infinite Loop", latitude: 37.3317, longitude: -122.0301)
        await CLIProbe.inWorld { world in
            world.helperRunning(true)
            world.answers { name in
                guard name == IPC.Name.calendarEvents else { return nil }
                return [
                    CalendarEventBridge.statusKey: "ok",
                    CalendarEventBridge.payloadKey: CalendarEventBridge.encode([event]),
                ]
            }
            let plain = await CLIProbe.capture(["calendar", "directions", "visit"])
            #expect(plain.code == 0)
            #expect(plain.stdout == "opening directions to 1 Infinite Loop\n")
            #expect(world.recordedURLs().last?.host == "maps.apple.com")

            let json = await CLIProbe.capture(
                ["calendar", "directions", "Studio visit", "--json"])
            #expect(json.code == 0)
            #expect(json.object?["action"] as? String == "directions")
            #expect(json.object?["id"] as? String == "visit")
            #expect(json.object?["location"] as? String == "1 Infinite Loop")
            #expect(json.object?["opened"] as? Bool == true)
            #expect((json.object?["url"] as? String)?.contains("maps.apple.com") == true)
        }
    }

    @Test func calendarListCanRequestTheFullWindowAndRejectsMore() async {
        let event = CalendarEventPayload(
            id: "distant", title: "Distant planning",
            start: Date().addingTimeInterval(119 * 86400),
            end: Date().addingTimeInterval(119 * 86400 + 3600), isAllDay: false)
        await CLIProbe.inWorld { world in
            world.helperRunning(true)
            world.answers { name in
                guard name == IPC.Name.calendarEvents else { return nil }
                return [
                    CalendarEventBridge.statusKey: "ok",
                    CalendarEventBridge.payloadKey: CalendarEventBridge.encode([event]),
                ]
            }
            let full = await CLIProbe.capture(["calendar", "ls", "--days", "120", "--json"])
            #expect(full.code == 0)
            #expect((full.array?.first as? [String: Any])?["id"] as? String == "distant")

            let tooMany = await CLIProbe.capture(["calendar", "ls", "--days", "121"])
            #expect(tooMany.code == 2)
            #expect(tooMany.stderr.contains("--days must be between 0 and 120"))
        }
    }

    @Test func presenterPlainAndJSONOutputsShareTheRuntime() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Presenter.enabled)
            let plain = await CLIProbe.capture(["presenter", "start"])
            #expect(plain.code == 0)
            #expect(plain.stdout == "presenter mode started\n")
            let json = await CLIProbe.capture(["presenter", "status", "--json"])
            #expect(json.code == 0)
            #expect(json.object?["manual"] as? Bool == true)
            #expect(json.object?["active"] as? Bool == true)
        }
    }
}
