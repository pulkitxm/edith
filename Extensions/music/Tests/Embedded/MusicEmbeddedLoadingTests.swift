import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicEmbeddedUI

@MainActor @Suite(.serialized) struct MusicEmbeddedLoadingTests {
    private let root = URL(fileURLWithPath: "/tmp/mock-music-library")

    private func entry(_ path: String) -> EmbeddedMusicUIEntry {
        .init(path: path, url: root.appendingPathComponent(path))
    }

    private func state(folderTracks: [String]) -> EmbeddedMusicUIState {
        EmbeddedMusicUIState(
            root: root, folders: [], folderTracks: folderTracks.map(entry), favourites: [],
            playback: .init(
                path: nil, playing: false, elapsed: 0, duration: 0, volume: 0.5, shuffle: false,
                repeating: false),
            selected: "local",
            spotify: .init(
                connected: false, connecting: false, account: "", title: "", uri: "", artist: "",
                album: "", playing: false, elapsed: 0, duration: 0, volume: 0.7),
            youtubeConnecting: false, youtubeConnected: false, restorePending: 0, events: [],
            cursor: 0, privacy: false)
    }

    private func settle(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !ready() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready())
    }

    @Test func cachedFolderShowsBeforeTheFreshReadFinishes() async throws {
        let remote = EmbeddedMusicRemote()
        let fresh = try JSONEncoder().encode(state(folderTracks: ["A/fresh.wav"]))
        let cached = try JSONEncoder().encode(
            EmbeddedMusicUIListing(folders: [], tracks: [entry("A/cached.wav")])
                as EmbeddedMusicUIListing?)
        var release: CheckedContinuation<Data, Error>?
        remote.configure { operation, _ in
            switch operation {
            case "music.ui.cachedListing": return cached
            case "music.ui.read":
                return try await withCheckedThrowingContinuation { release = $0 }
            default: return Data("{}".utf8)
            }
        }
        defer { remote.stop() }
        remote.navigate(to: "A")
        try await settle { remote.entriesLoaded }
        #expect(remote.folderTracks.map(\.relativePath) == ["A/cached.wav"])
        try await settle { release != nil }
        release?.resume(returning: fresh)
        try await settle { remote.folderTracks.map(\.relativePath) == ["A/fresh.wav"] }
        #expect(remote.entriesLoaded)
    }

    @Test func missingCacheKeepsTheSkeletonUntilTheFreshRead() async throws {
        let remote = EmbeddedMusicRemote()
        let fresh = try JSONEncoder().encode(state(folderTracks: ["A/fresh.wav"]))
        var release: CheckedContinuation<Data, Error>?
        remote.configure { operation, _ in
            switch operation {
            case "music.ui.cachedListing": return Data("null".utf8)
            case "music.ui.read":
                return try await withCheckedThrowingContinuation { release = $0 }
            default: return Data("{}".utf8)
            }
        }
        defer { remote.stop() }
        remote.navigate(to: "A")
        try await settle { release != nil }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!remote.entriesLoaded)
        release?.resume(returning: fresh)
        try await settle { remote.entriesLoaded }
    }

    @Test func readNoLongerCarriesTheCatalogOrSearch() async throws {
        let remote = EmbeddedMusicRemote()
        var operations: [String] = []
        let fresh = try JSONEncoder().encode(state(folderTracks: ["A/one.wav"]))
        remote.configure { operation, _ in
            operations.append(operation)
            return operation == "music.ui.read" ? fresh : Data("{}".utf8)
        }
        defer { remote.stop() }
        remote.rescan()
        try await settle { remote.entriesLoaded }
        #expect(operations == ["music.ui.read"])
        #expect(remote.tracks.isEmpty)
    }

    @Test func searchWaitsUntilTypingPauses() async throws {
        let remote = EmbeddedMusicRemote()
        remote.searchDelay = .milliseconds(80)
        var requests: [EmbeddedMusicUISearchRequest] = []
        let empty = try JSONEncoder().encode(EmbeddedMusicUIListing(folders: [], tracks: []))
        remote.configure { operation, payload in
            if operation == "music.ui.search" {
                requests.append(
                    try JSONDecoder().decode(EmbeddedMusicUISearchRequest.self, from: payload))
            }
            return empty
        }
        defer { remote.stop() }
        remote.noteSearch("a")
        remote.noteSearch("ab")
        try await Task.sleep(for: .milliseconds(30))
        #expect(requests.isEmpty)
        try await settle { requests.count == 2 }
        #expect(requests.map(\.search) == ["ab", "ab"])
    }

    @Test func searchPublishesTheFirstPageBeforeTheRemainder() async throws {
        let remote = EmbeddedMusicRemote()
        remote.searchDelay = .milliseconds(1)
        let first = try JSONEncoder().encode(
            EmbeddedMusicUIListing(folders: [], tracks: [entry("a.wav")]))
        let rest = try JSONEncoder().encode(
            EmbeddedMusicUIListing(folders: [], tracks: [entry("b.wav")]))
        var requests: [EmbeddedMusicUISearchRequest] = []
        var release: CheckedContinuation<Data, Error>?
        remote.configure { operation, payload in
            let request = try JSONDecoder().decode(EmbeddedMusicUISearchRequest.self, from: payload)
            requests.append(request)
            if request.skip == 0 { return first }
            return try await withCheckedThrowingContinuation { release = $0 }
        }
        defer { remote.stop() }
        remote.noteSearch("song")
        try await settle { remote.searchLoaded }
        #expect(remote.searchTracks.map(\.relativePath) == ["a.wav"])
        try await settle { release != nil }
        #expect(requests.map(\.limit) == [EmbeddedMusicRemote.searchPageSize, nil])
        #expect(requests.last?.skip == EmbeddedMusicRemote.searchPageSize)
        release?.resume(returning: rest)
        try await settle { remote.searchTracks.count == 2 }
        #expect(remote.searchTracks.map(\.relativePath) == ["a.wav", "b.wav"])
    }

    @Test func clearingTheSearchDropsInFlightResults() async throws {
        let remote = EmbeddedMusicRemote()
        remote.searchDelay = .milliseconds(1)
        let first = try JSONEncoder().encode(
            EmbeddedMusicUIListing(folders: [], tracks: [entry("a.wav")]))
        var release: CheckedContinuation<Data, Error>?
        remote.configure { _, _ in
            try await withCheckedThrowingContinuation { release = $0 }
        }
        defer { remote.stop() }
        remote.noteSearch("song")
        try await settle { release != nil }
        remote.noteSearch("")
        release?.resume(returning: first)
        try await Task.sleep(for: .milliseconds(40))
        #expect(remote.searchTracks.isEmpty)
        #expect(!remote.searchLoaded)
    }

    @Test func catalogLoadsOnDemandOnly() async throws {
        let remote = EmbeddedMusicRemote()
        var catalogCalls = 0
        let catalog = try JSONEncoder().encode([entry("a.wav"), entry("b.wav")])
        remote.configure { operation, _ in
            guard operation == "music.ui.catalog" else { return Data("{}".utf8) }
            catalogCalls += 1
            return catalog
        }
        defer { remote.stop() }
        remote.rescan()
        try await Task.sleep(for: .milliseconds(30))
        #expect(catalogCalls == 0)
        remote.loadCatalog()
        remote.loadCatalog()
        try await settle { remote.catalogLoaded }
        #expect(remote.tracks.count == 2)
        #expect(catalogCalls == 1)
    }
}
