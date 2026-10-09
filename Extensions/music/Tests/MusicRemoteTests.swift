import Foundation
import Testing

@testable import MusicExtension
import EdithExtensionSupport
import EdithExtensionUI

extension MusicExtensionTests {
    @MainActor @Suite struct MusicRemoteTests {
        @Test func appliesStateFromNotificationInfo() {
            let remote = MusicRemote()
            remote.apply([
                "track": "song.mp3", "isPlaying": true, "duration": 240.0,
                "looping": true, "volume": 0.4, "elapsed": 30.0,
                "at": Date().timeIntervalSince1970,
            ])
            #expect(remote.currentFile == "song.mp3")
            #expect(remote.isPlaying)
            #expect(remote.duration == 240)
            #expect(remote.looping)
            #expect(remote.volume == 0.4)
            #expect(abs(remote.elapsed - 30) < 1)
        }

        @Test func emptyTrackClearsCurrentFile() {
            let remote = MusicRemote()
            remote.apply(["track": ""])
            #expect(remote.currentFile == nil)
            #expect(!remote.isPlaying)
            #expect(remote.duration == 0)
        }

        @Test func missingVolumeKeepsPreviousValue() {
            let remote = MusicRemote()
            remote.apply(["volume": 0.25])
            remote.apply(["track": "song.mp3"])
            #expect(remote.volume == 0.25)
        }

        @Test func elapsedClampsToDuration() {
            let remote = MusicRemote()
            remote.apply([
                "elapsed": 500.0, "duration": 100.0, "isPlaying": false,
                "at": Date().timeIntervalSince1970,
            ])
            #expect(remote.elapsed == 100)
            #expect(remote.progress == 1)
        }

        @Test func elapsedNeverGoesNegative() {
            let remote = MusicRemote()
            remote.apply([
                "elapsed": -20.0, "duration": 100.0, "isPlaying": false,
                "at": Date().timeIntervalSince1970,
            ])
            #expect(remote.elapsed == 0)
            #expect(remote.progress == 0)
        }

        @Test func zeroDurationYieldsZeroProgress() {
            let remote = MusicRemote()
            remote.apply(["elapsed": 42.0, "duration": 0.0, "isPlaying": false])
            #expect(remote.progress == 0)
        }

        @Test func folderMenusArePreloadedOffMainThread() async {
            let root = URL(fileURLWithPath: "/tmp/music-menu-fixture")
            let folder = MusicFolder(
                url: root.appendingPathComponent("Albums"), relativePath: "Albums")
            let remote = MusicRemote(
                listSubfolders: { _ in
                    #expect(!Thread.isMainThread)
                    return [folder]
                },
                listFolder: { path in
                    #expect(!Thread.isMainThread)
                    return MusicLibraryContentListing(
                        folder: MusicFolder(
                            url: root.appendingPathComponent(path), relativePath: path),
                        folders: [], tracks: [])
                })
            #expect(remote.subfolders(of: "") == nil)
            remote.navigate(to: "Albums/Focus")
            #expect(await waitUntil { remote.entriesLoaded })
            #expect(remote.subfolders(of: "")?.map(\.relativePath) == ["Albums"])
            #expect(remote.subfolders(of: "Albums")?.map(\.relativePath) == ["Albums"])
            #expect(remote.subfolders(of: "Albums/Focus")?.isEmpty == true)
        }

        @Test func favouritesLoadOffMainThreadAndDoNotPublishAfterStop() async {
            let fixture = MusicRemoteLoadFixture()
            let remote = MusicRemote(scanFavourites: {
                #expect(!Thread.isMainThread)
                return fixture.scan()
            })
            remote.openFavourites()
            #expect(!remote.favouritesLoaded)
            #expect(await fixture.waitForFirstStart())
            remote.stop()
            fixture.releaseFirst()
            #expect(await fixture.waitForFirstFinish())
            try? await Task.sleep(for: .milliseconds(50))
            #expect(!remote.favouritesLoaded)
            #expect(remote.favourites.isEmpty)
            remote.openFavourites()
            #expect(await waitUntil { remote.favouritesLoaded })
            #expect(remote.favourites.map(\.relativePath) == ["new.mp3"])
        }

        @Test func emptyFolderOnlyBecomesEmptyAfterItsListingFinishes() async {
            let root = URL(fileURLWithPath: "/tmp/music-loading-fixture")
            let remote = MusicRemote(listFolder: { path in
                MusicLibraryContentListing(
                    folder: MusicFolder(url: root.appendingPathComponent(path), relativePath: path),
                    folders: [], tracks: [])
            })
            remote.navigate(to: "Empty")
            #expect(!remote.entriesLoaded)
            #expect(await waitUntil { remote.entriesLoaded })
            #expect(remote.folderTracks.isEmpty)
            remote.navigate(to: "Another")
            #expect(!remote.entriesLoaded)
            #expect(await waitUntil { remote.entriesLoaded })
            remote.stop()
            #expect(!remote.entriesLoaded)
            #expect(!remote.searchLoaded)
        }

        @Test func newestSameFolderListingWinsAfterTheOlderTaskFinishes() async {
            let fixture = MusicRemoteLoadFixture()
            let remote = MusicRemote(listFolder: { fixture.list($0) })
            #expect(!remote.entriesLoaded)
            remote.navigate(to: "Focus")
            #expect(await fixture.waitForFirstStart())
            #expect(!remote.entriesLoaded)

            remote.navigate(to: "Focus")
            #expect(
                await waitUntil { remote.folderTracks.map(\.relativePath) == ["Focus/new.mp3"] })
            fixture.releaseFirst()
            #expect(await fixture.waitForFirstFinish())
            try? await Task.sleep(for: .milliseconds(50))

            #expect(remote.folderTracks.map(\.relativePath) == ["Focus/new.mp3"])
            #expect(remote.entriesLoaded)
        }

        @Test func newestRescanWinsAndStopRejectsAStaleCatalog() async {
            let fixture = MusicRemoteLoadFixture()
            let remote = MusicRemote(
                listFolder: { path in
                    MusicLibraryContentListing(
                        folder: MusicFolder(
                            url: URL(fileURLWithPath: "/tmp/\(path)"), relativePath: path),
                        folders: [], tracks: [])
                }, catalog: { fixture.scan() })
            remote.rescan()
            #expect(await fixture.waitForFirstStart())

            remote.rescan()
            #expect(await waitUntil { remote.tracks.map(\.relativePath) == ["new.mp3"] })
            fixture.releaseFirst()
            #expect(await fixture.waitForFirstFinish())
            try? await Task.sleep(for: .milliseconds(50))
            #expect(remote.tracks.map(\.relativePath) == ["new.mp3"])

            let stoppedFixture = MusicRemoteLoadFixture()
            let stopped = MusicRemote(
                listFolder: { path in
                    MusicLibraryContentListing(
                        folder: MusicFolder(
                            url: URL(fileURLWithPath: "/tmp/\(path)"), relativePath: path),
                        folders: [], tracks: [])
                }, catalog: { stoppedFixture.scan() })
            stopped.rescan()
            #expect(await stoppedFixture.waitForFirstStart())
            stopped.stop()
            stoppedFixture.releaseFirst()
            #expect(await stoppedFixture.waitForFirstFinish())
            try? await Task.sleep(for: .milliseconds(50))
            #expect(stopped.tracks.isEmpty)
        }

        @Test func rescanRejectsAnOlderFolderListing() async {
            let listing = MusicRemoteLoadFixture()
            let remote = MusicRemote(listFolder: { listing.list($0) })
            remote.navigate(to: "")
            #expect(await listing.waitForFirstStart())

            remote.rescan()
            #expect(await waitUntil { remote.folderTracks.map(\.relativePath) == ["/new.mp3"] })
            listing.releaseFirst()
            #expect(await listing.waitForFirstFinish())
            try? await Task.sleep(for: .milliseconds(50))
            #expect(remote.folderTracks.map(\.relativePath) == ["/new.mp3"])
        }

        @Test func searchGenerationHandlesFolderAtoBtoA() async {
            let fixture = MusicRemoteLoadFixture()
            let remote = MusicRemote(
                searchPage: { path, _ in
                    let found = fixture.search(path)
                    return MusicSearchPage(tracks: found.tracks, folders: found.folders)
                }, searchRemainder: { _, _ in MusicSearchPage() })
            remote.navigate(to: "A")
            remote.loadSearchScope()
            #expect(await fixture.waitForFirstStart())

            remote.navigate(to: "B")
            remote.loadSearchScope()
            remote.navigate(to: "A")
            remote.loadSearchScope()
            #expect(await waitUntil { remote.searchTracks.map(\.relativePath) == ["A/new.mp3"] })
            fixture.releaseFirst()
            #expect(await fixture.waitForFirstFinish())
            try? await Task.sleep(for: .milliseconds(50))

            #expect(remote.searchTracks.map(\.relativePath) == ["A/new.mp3"])
            #expect(remote.searchLoaded)
        }

        @Test func openingAFolderDoesNotListSiblingTrees() async {
            var listed: [String] = []
            let root = URL(fileURLWithPath: "/tmp/music-siblings")
            let remote = MusicRemote(
                listSubfolders: { path in
                    listed.append("sub:\(path)")
                    return []
                },
                listFolder: { path in
                    listed.append(path)
                    return MusicLibraryContentListing(
                        folder: MusicFolder(
                            url: root.appendingPathComponent(path), relativePath: path),
                        folders: [],
                        tracks: [
                            Track(
                                url: root.appendingPathComponent("\(path)/one.mp3"),
                                relativePath: "\(path)/one.mp3")
                        ])
                })
            remote.navigate(to: "A")
            #expect(await waitUntil { remote.entriesLoaded })
            #expect(listed.contains("A"))
            #expect(!listed.contains("B"))
            #expect(remote.folderTracks.map(\.relativePath) == ["A/one.mp3"])
        }

        @Test func cachedFolderShowsBeforeRefreshFinishes() async {
            let gate = MusicRemoteLoadFixture()
            let root = URL(fileURLWithPath: "/tmp/music-cached-folder")
            let cached = Track(
                url: root.appendingPathComponent("A/cached.mp3"), relativePath: "A/cached.mp3")
            let remote = MusicRemote(
                listFolder: { gate.list($0) },
                listingCache: MusicListingCache(
                    load: { path in
                        guard path == "A" else { return nil }
                        return MusicLibraryContentListing(
                            folder: MusicFolder(
                                url: root.appendingPathComponent(path), relativePath: path),
                            folders: [], tracks: [cached])
                    }, save: { _, _ in }))
            remote.navigate(to: "A")
            #expect(await waitUntil { remote.folderTracks.map(\.relativePath) == ["A/cached.mp3"] })
            #expect(remote.entriesLoaded)
            gate.releaseFirst()
            #expect(await waitUntil { remote.folderTracks.map(\.relativePath) == ["A/old.mp3"] })
        }

        @Test func searchWaitsUntilTypingPauses() async {
            let calls = SearchCalls()
            let remote = MusicRemote(
                searchPage: { _, query in
                    calls.add(query)
                    return MusicSearchPage()
                }, searchRemainder: { _, _ in MusicSearchPage() })
            remote.searchDelay = .milliseconds(80)
            remote.noteSearch("a")
            remote.noteSearch("ab")
            try? await Task.sleep(for: .milliseconds(30))
            #expect(calls.values.isEmpty)
            #expect(await waitUntil { calls.values == ["ab"] })
        }

        @Test func searchPublishesTheFirstPageBeforeTheRemainder() async {
            let gate = MusicRemoteLoadFixture()
            let root = URL(fileURLWithPath: "/tmp/music-search-page")
            let remote = MusicRemote(
                searchPage: { _, _ in
                    MusicSearchPage(tracks: [
                        Track(url: root.appendingPathComponent("a.mp3"), relativePath: "a.mp3")
                    ])
                },
                searchRemainder: { _, _ in
                    _ = gate.scan()
                    return MusicSearchPage(tracks: [
                        Track(url: root.appendingPathComponent("b.mp3"), relativePath: "b.mp3")
                    ])
                })
            remote.loadSearchScope(matching: "song")
            #expect(await waitUntil { remote.searchTracks.map(\.relativePath) == ["a.mp3"] })
            #expect(remote.searchLoaded)
            #expect(await gate.waitForFirstStart())
            gate.releaseFirst()
            #expect(
                await waitUntil { remote.searchTracks.map(\.relativePath) == ["a.mp3", "b.mp3"] })
        }

        @Test func failedMutationPublishesAReadableError() {
            let remote = MusicRemote()

            remote.createFolder(named: "   ")

            #expect(remote.libraryError == "a name cannot be blank")
            remote.dismissLibraryError()
            #expect(remote.libraryError == nil)
        }

        private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
            for _ in 0..<200 {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
    }

    private final class SearchCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        func add(_ query: String) {
            lock.withLock { stored.append(query) }
        }

        var values: [String] {
            lock.withLock { stored }
        }
    }

    private final class MusicRemoteLoadFixture: @unchecked Sendable {
        private let lock = NSLock()
        private let firstStarted = DispatchSemaphore(value: 0)
        private let firstReleased = DispatchSemaphore(value: 0)
        private let firstFinished = DispatchSemaphore(value: 0)
        private var calls = 0
        private let root = URL(fileURLWithPath: "/tmp/music-remote-load")

        func list(_ path: String) -> MusicLibraryContentListing {
            let call = nextCall()
            if call == 1 { blockFirst() }
            let track = Track(
                url: root.appendingPathComponent("\(path)/\(call == 1 ? "old" : "new").mp3"),
                relativePath: "\(path)/\(call == 1 ? "old" : "new").mp3")
            return MusicLibraryContentListing(
                folder: MusicFolder(url: root.appendingPathComponent(path), relativePath: path),
                folders: [], tracks: [track])
        }

        func scan() -> [Track] {
            let call = nextCall()
            if call == 1 { blockFirst() }
            let name = call == 1 ? "old.mp3" : "new.mp3"
            return [Track(url: root.appendingPathComponent(name), relativePath: name)]
        }

        func search(_ path: String) -> (tracks: [Track], folders: [MusicFolder]) {
            let call = nextCall()
            if call == 1 { blockFirst() }
            let suffix = call == 1 ? "old" : "new"
            return (
                [
                    Track(
                        url: root.appendingPathComponent("\(path)/\(suffix).mp3"),
                        relativePath: "\(path)/\(suffix).mp3")
                ], []
            )
        }

        func waitForFirstStart() async -> Bool {
            await Task.detached { self.waitForFirstStartSynchronously() }.value
        }

        func releaseFirst() {
            firstReleased.signal()
        }

        func waitForFirstFinish() async -> Bool {
            await Task.detached { self.waitForFirstFinishSynchronously() }.value
        }

        private func nextCall() -> Int {
            lock.withLock {
                calls += 1
                return calls
            }
        }

        private func blockFirst() {
            firstStarted.signal()
            firstReleased.wait()
            firstFinished.signal()
        }

        private func waitForFirstStartSynchronously() -> Bool {
            firstStarted.wait(timeout: .now() + 2) == .success
        }

        private func waitForFirstFinishSynchronously() -> Bool {
            firstFinished.wait(timeout: .now() + 2) == .success
        }
    }

}
