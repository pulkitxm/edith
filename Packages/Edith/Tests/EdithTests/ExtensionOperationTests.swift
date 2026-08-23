import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct ExtensionOperationDescriptorTests {
    @Test func descriptorsAreUniqueAndRegistered() {
        let descriptors =
            CalendarEventOperation.allCases.map(\.descriptor)
            + ShelfItemOperation.allCases.map(\.descriptor)
            + MusicLibraryOperation.allCases.map(\.descriptor)
            + MusicTransportOperation.allCases.map(\.descriptor)
            + PresenterRuntimeOperation.allCases.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        #expect(descriptors.allSatisfy { UserOperationCatalog.descriptor(id: $0.id) == $0 })
        #expect(descriptors.allSatisfy { !$0.requiresPreview })
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
        #expect(shelf.candidates == ["1", "2"])
        #expect(music.candidates == ["Focus/song.mp3"])
        #expect(calendar.candidates == ["event-1"])
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
