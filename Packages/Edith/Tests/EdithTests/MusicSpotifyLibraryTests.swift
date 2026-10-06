import Foundation
import Testing

@testable import Edith

@MainActor @Suite struct MusicSpotifyLibraryTests {
    private final class Commands {
        var values: [[String: Any]] = []
        func last(_ kind: String) -> [String: Any] {
            values.last { $0["kind"] as? String == kind }!
        }
    }

    private func ready(
        _ commands: Commands, timeout: Duration = .seconds(30),
        playlistTimeout: Duration = .seconds(95)
    ) -> MusicSpotifyLibrary {
        let library = MusicSpotifyLibrary(timeout: timeout, playlistTimeout: playlistTimeout) {
            commands.values.append($0)
        }
        library.apply(["event": "libraryState", "ready": true, "authorizing": false])
        return library
    }

    private func item(_ suffix: String = "0", kind: String = "track") -> SpotifyCatalogItem {
        let id = String(repeating: "a", count: 21) + suffix
        return SpotifyCatalogItem(
            id: id, uri: "spotify:\(kind):\(id)", kind: kind, title: "Sample \(suffix)",
            subtitle: "Sample artist", duration: 180)
    }

    private func respond(
        _ library: MusicSpotifyLibrary, to command: [String: Any], items: [SpotifyCatalogItem],
        next: Int? = nil, cursor: String? = nil, current: SpotifyCatalogItem? = nil,
        error: String? = nil
    ) throws {
        var event: [String: Any] = [
            "event": "catalog", "requestId": command["requestId"]!,
            "items": try JSONSerialization.jsonObject(with: JSONEncoder().encode(items)),
        ]
        if let next { event["nextOffset"] = next }
        if let cursor { event["nextCursor"] = cursor }
        if let error { event["error"] = error }
        if let current {
            event["current"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
        }
        library.apply(event)
    }

    @Test func authorizationAndInitialRequestsAreIndependent() throws {
        let commands = Commands()
        let library = MusicSpotifyLibrary { commands.values.append($0) }
        library.activate()
        #expect(commands.values.isEmpty)
        library.authorize()
        library.authorize()
        #expect(commands.values.count == 1)
        library.apply(["event": "libraryState", "ready": true, "authorizing": false])
        #expect(library.libraryReady && !library.authorizing && library.loading)
        let requests = commands.values.filter { $0["action"] as? String == "catalog" }
        #expect(Set(requests.compactMap { $0["requestId"] as? String }).count == 8)
        for command in requests.reversed() {
            try respond(library, to: command, items: [item()])
        }
        #expect(!library.loading && library.playlists.count == 1 && library.topTracks.count == 1)
    }

    @Test func newerSearchOwnsResultsAndHistory() throws {
        let commands = Commands()
        let library = ready(commands)
        library.search("first")
        let old = commands.last("search")
        library.search("second")
        let new = commands.last("search")
        try respond(library, to: new, items: [item("2")])
        try respond(library, to: old, items: [item("1")])
        #expect(library.items == [item("2")])
        library.back()
        #expect(library.currentDestination == .search("first") && library.canGoForward)
        library.search("third")
        #expect(!library.canGoForward)
    }

    @Test func collectionPagingDeduplicatesAndIgnoresOldRoute() throws {
        let commands = Commands()
        let library = ready(commands)
        let album = item(kind: "album")
        library.open(album)
        try respond(library, to: commands.last("album"), items: [item()], next: 1, current: album)
        library.loadMore()
        let page = commands.last("album")
        #expect(page["offset"] as? Int == 1)
        try respond(library, to: page, items: [item(), item("1")])
        #expect(library.items.count == 3 && library.collection == album && !library.canLoadMore)
        library.play(item(), index: 1)
        #expect(commands.values.last?["uri"] as? String == album.uri)
        #expect(commands.values.last?["index"] as? Int == 1)
        var positioned = item()
        positioned.position = 4
        library.play(positioned, index: 1)
        #expect(commands.values.last?["index"] as? Int == 4)
        library.refresh()
        let old = commands.last("album")
        library.navigate(to: .library("liked"))
        try respond(library, to: old, items: [item("2")])
        #expect(library.items.isEmpty)
        try respond(library, to: commands.last("liked"), items: [item("3")])
        #expect(library.items == [item("3")])
    }

    @Test func refreshFailureRetainsContentAndRecoveryReplacesIt() throws {
        let commands = Commands()
        let library = ready(commands)
        library.search("sample")
        try respond(library, to: commands.last("search"), items: [item()])
        library.refresh()
        #expect(library.load.isRefreshing)
        try respond(library, to: commands.last("search"), items: [], error: "Sample unavailable")
        #expect(library.items == [item()] && library.error == "Sample unavailable")
        library.refresh()
        try respond(library, to: commands.last("search"), items: [item("1")])
        #expect(library.items == [item("1")] && library.error == nil)
    }

    @Test func timeoutAndResetRejectLateResponses() async throws {
        let commands = Commands()
        let library = ready(commands, timeout: .milliseconds(1))
        library.search("sample")
        let timedOut = commands.last("search")
        for _ in 0..<100 where library.load.isRunning {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(!library.load.isRunning && library.error != nil)
        try respond(library, to: timedOut, items: [item()])
        #expect(library.items.isEmpty)
        library.refresh()
        let disconnected = commands.last("search")
        library.reset()
        try respond(library, to: disconnected, items: [item()])
        #expect(!library.libraryReady && library.items.isEmpty && library.error == nil)
        library.activate()
        library.apply(["event": "libraryState", "ready": true])
        #expect(commands.values.filter { $0["kind"] as? String == "playlists" }.count == 1)
    }

    @Test func playlistFallbackOwnsLongerDeadlineAndRejectsLateResponses() async throws {
        let commands = Commands()
        let library = ready(commands, timeout: .milliseconds(5), playlistTimeout: .seconds(1))
        library.open(item(kind: "playlist"))
        let request = commands.last("playlist")
        try await Task.sleep(for: .milliseconds(30))
        #expect(library.load.isRunning)
        try respond(library, to: request, items: [item()])
        #expect(library.items == [item()] && library.error == nil)
        let expiringCommands = Commands()
        let expiring = ready(
            expiringCommands, timeout: .seconds(1), playlistTimeout: .milliseconds(1))
        expiring.open(item(kind: "playlist"))
        let late = expiringCommands.last("playlist")
        for _ in 0..<100 where expiring.load.isRunning {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(!expiring.load.isRunning && expiring.error != nil)
        try respond(expiring, to: late, items: [item()])
        #expect(expiring.items.isEmpty)
    }

    @Test func invalidCatalogAndArtworkAreRejected() throws {
        let commands = Commands()
        let library = ready(commands)
        library.search("sample")
        var invalid = item()
        invalid.duration = -1
        try respond(library, to: commands.last("search"), items: [invalid])
        #expect(library.items.isEmpty && library.error != nil)
        var cover = item()
        cover.artwork = "https://i.scdn.co.evil.example/image/sample"
        #expect(cover.artworkURL == nil)
        cover.artwork = "https://mosaic.scdn.co/sample"
        #expect(cover.artworkURL != nil)
        library.refresh()
        library.apply([
            "event": "catalog", "requestId": commands.last("search")["requestId"]!,
            "items": "invalid",
        ])
        #expect(!library.load.isRunning && library.error != nil)
    }

    @Test func queueAndPlaybackCommandsPreserveCollectionIndex() throws {
        let commands = Commands()
        let library = ready(commands)
        library.showQueue()
        try respond(library, to: commands.last("queue"), items: [item("1")], current: item())
        #expect(library.queue == [item("1")] && library.current == item())
        library.play(item(kind: "album"), index: 3)
        #expect(commands.values.last?["index"] as? Int == 3)
        library.addToQueue(item())
        #expect(commands.values.last?["action"] as? String == "queueAdd")
        library.setShuffle(true)
        library.setRepeat("context")
        library.applyPlaybackState(["shuffle": true, "repeat": "context"])
        #expect(library.shuffle && library.repeatMode == "context")
        let count = commands.values.count
        library.setRepeat("invalid")
        library.createPlaylist("   ")
        #expect(commands.values.count == count)
    }

    @Test func mutationAcknowledgementsOwnSavedStateAndQueueErrorsStaySeparate() throws {
        let commands = Commands()
        let library = ready(commands)
        library.setSaved(item(), saved: true)
        #expect(library.savedURIs.isEmpty)
        library.apply([
            "event": "libraryChanged", "kind": "setSaved", "savedUri": item().uri,
            "saved": true,
        ])
        #expect(library.savedURIs.contains(item().uri))
        library.apply([
            "event": "libraryChanged", "kind": "setSaved", "savedUri": item().uri,
            "saved": false, "error": "Sample write failed",
        ])
        #expect(library.savedURIs.contains(item().uri))
        library.showQueue()
        try respond(library, to: commands.last("queue"), items: [], error: "Sample queue failed")
        #expect(library.queueError == "Sample queue failed")
        #expect(library.error == "Sample write failed")
        library.apply([
            "event": "libraryChanged", "kind": "savedState", "savedUri": item().uri,
            "saved": false,
        ])
        #expect(!library.savedURIs.contains(item().uri))
    }

    @Test func followedArtistCursorPagingAndSavedLibraryState() throws {
        let commands = Commands()
        let library = ready(commands)
        library.navigate(to: .library("artists"))
        let artist = item(kind: "artist")
        try respond(library, to: commands.last("artists"), items: [artist], cursor: "sample-cursor")
        #expect(library.savedURIs.contains(artist.uri))
        library.loadMore()
        #expect(commands.last("artists")["cursor"] as? String == "sample-cursor")
        try respond(library, to: commands.last("artists"), items: [item("1", kind: "artist")])
        #expect(library.items.count == 2 && !library.canLoadMore)
    }

    @Test func partialHomeFailureKeepsSuccessfulShelvesVisible() throws {
        let commands = Commands()
        let library = ready(commands)
        library.activate()
        for command in commands.values {
            if command["kind"] as? String == "recent" {
                try respond(library, to: command, items: [item()])
            } else {
                try respond(library, to: command, items: [], error: "Sample shelf failed")
            }
        }
        #expect(library.load.hasContent && !library.load.isRunning && library.recent == [item()])
        #expect(library.error == "Sample shelf failed")
    }

    @Test func savedPlaylistsRemainVisibleWithoutListeningHistory() throws {
        let commands = Commands()
        let library = ready(commands)
        library.activate()
        for command in commands.values {
            let values = command["kind"] as? String == "playlists" ? [item(kind: "playlist")] : []
            try respond(library, to: command, items: values)
        }
        #expect(library.playlists.count == 1 && library.recent.isEmpty && library.topTracks.isEmpty)
        #expect(library.load.state == .content && library.error == nil)
    }

    @Test func backgroundShelfErrorsDoNotReplaceVisibleSearchRecovery() throws {
        let commands = Commands()
        let library = ready(commands)
        library.activate()
        let shelf = commands.last("recent")
        library.search("sample")
        try respond(library, to: shelf, items: [], error: "Sample background failure")
        #expect(library.error == nil)
        try respond(library, to: commands.last("search"), items: [], error: "Sample search failure")
        library.refresh()
        try respond(library, to: commands.last("search"), items: [item()])
        #expect(library.error == nil && library.items == [item()])
        library.navigate(to: .queue)
        try respond(library, to: commands.last("queue"), items: [item(), item()])
        #expect(library.queue.count == 2 && library.items.count == 2)
    }

    @Test func sessionDelegatesLibraryEventsAndOptionDeltasPreservePlayback() {
        let defaults = UserDefaults(suiteName: "test.music.library.\(UUID().uuidString)")!
        let session = MusicSpotifySession(executable: nil, defaults: defaults)
        let events = """
            {"event":"connected","account":"sample listener"}
            {"event":"libraryState","ready":true,"authorizing":false}
            {"event":"track","uri":"spotify:track:aaaaaaaaaaaaaaaaaaaaa0","duration":180}
            {"event":"state","playing":true,"elapsed":15}
            {"event":"state","shuffle":true,"repeat":"track"}

            """
        session.receive(Data(events.utf8), generation: session.generation)
        #expect(session.library.libraryReady && session.library.shuffle)
        #expect(session.playing && session.elapsed >= 15 && session.uri.hasPrefix("spotify:track:"))
        session.stop()
        #expect(!session.library.libraryReady && session.uri.isEmpty)
    }

    @Test func sessionBoundsIndividualFramesInsteadOfCombinedCatalogDelivery() {
        let defaults = UserDefaults(suiteName: "test.music.catalog.frames.\(UUID().uuidString)")!
        let session = MusicSpotifySession(executable: nil, defaults: defaults)
        let padding = String(repeating: "x", count: 40_000)
        let frame = "{\"event\":\"unused\",\"padding\":\"\(padding)\"}\n"
        let connected = "{\"event\":\"connected\",\"account\":\"sample listener\"}\n"
        session.receive(Data((frame + frame + connected).utf8), generation: session.generation)
        #expect(session.connected && session.error == nil)
    }
}
