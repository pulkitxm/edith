import Foundation
import Testing
@testable import Edith

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
}
