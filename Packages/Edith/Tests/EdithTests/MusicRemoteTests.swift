import Foundation
import Testing
@testable import Edith
@testable import EdithKit

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

    @Test func newestSameFolderListingWinsAfterTheOlderTaskFinishes() async {
        let fixture = MusicRemoteLoadFixture()
        let remote = MusicRemote(listFolder: { fixture.list($0) })
        remote.navigate(to: "Focus")
        #expect(await fixture.waitForFirstStart())

        remote.navigate(to: "Focus")
        #expect(await waitUntil { remote.folderTracks.map(\.relativePath) == ["Focus/new.mp3"] })
        fixture.releaseFirst()
        #expect(await fixture.waitForFirstFinish())
        try? await Task.sleep(for: .milliseconds(50))

        #expect(remote.folderTracks.map(\.relativePath) == ["Focus/new.mp3"])
    }

    @Test func newestRescanWinsAndStopRejectsAStaleScan() async {
        let fixture = MusicRemoteLoadFixture()
        let remote = MusicRemote(scanLibrary: { fixture.scan() })
        remote.rescan()
        #expect(await fixture.waitForFirstStart())

        remote.rescan()
        #expect(await waitUntil { remote.tracks.map(\.relativePath) == ["new.mp3"] })
        fixture.releaseFirst()
        #expect(await fixture.waitForFirstFinish())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(remote.tracks.map(\.relativePath) == ["new.mp3"])

        let stoppedFixture = MusicRemoteLoadFixture()
        let stopped = MusicRemote(scanLibrary: { stoppedFixture.scan() })
        stopped.rescan()
        #expect(await stoppedFixture.waitForFirstStart())
        stopped.stop()
        stoppedFixture.releaseFirst()
        #expect(await stoppedFixture.waitForFirstFinish())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(stopped.tracks.isEmpty)
    }

    @Test func rescanRejectsAnOlderFolderListingBeforeTheScanFinishes() async {
        let listing = MusicRemoteLoadFixture()
        let scanning = MusicRemoteLoadFixture()
        let remote = MusicRemote(
            scanLibrary: { scanning.scan() }, listFolder: { listing.list($0) })
        remote.navigate(to: "")
        #expect(await listing.waitForFirstStart())

        remote.rescan()
        #expect(await scanning.waitForFirstStart())
        listing.releaseFirst()
        #expect(await listing.waitForFirstFinish())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(remote.folderTracks.isEmpty)

        scanning.releaseFirst()
        #expect(await scanning.waitForFirstFinish())
        #expect(await waitUntil { remote.folderTracks.map(\.relativePath) == ["/new.mp3"] })
    }

    @Test func searchGenerationHandlesFolderAtoBtoA() async {
        let fixture = MusicRemoteLoadFixture()
        let remote = MusicRemote(searchFolder: { fixture.search($0) })
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
