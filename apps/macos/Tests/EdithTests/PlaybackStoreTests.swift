import Foundation
import Testing
@testable import EdithMenuBar

@Suite struct PlaybackStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "PlaybackStoreTests-\(UUID().uuidString)")!
    }

    @Test func roundTripsPlayingState() {
        let defaults = freshDefaults()
        PlaybackStore.save(track: "song.mp3", position: 42, playing: true, into: defaults)
        #expect(
            PlaybackStore.load(from: defaults)
                == PlaybackStore.Snapshot(track: "song.mp3", position: 42, playing: true))
    }

    @Test func roundTripsPausedState() {
        let defaults = freshDefaults()
        PlaybackStore.save(track: "a.mp3", position: 0, playing: false, into: defaults)
        #expect(PlaybackStore.load(from: defaults)?.playing == false)
    }

    @Test func returnsNilWithoutSavedTrack() {
        #expect(PlaybackStore.load(from: freshDefaults()) == nil)
    }
}
