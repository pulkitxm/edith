import CoreGraphics
import Foundation
import Testing

@testable import EdithHelper

@Suite struct ExternalNowPlayingParseTests {
    @Test func parsesPlayingSpotifyTrack() {
        let track = ExternalNowPlaying.parse(
            app: .spotify,
            userInfo: [
                "Player State": "Playing",
                "Name": "Nobody's Son",
                "Artist": "Sabrina Carpenter",
                "Duration": NSNumber(value: 215_000),
            ])
        #expect(track?.title == "Nobody's Son")
        #expect(track?.artist == "Sabrina Carpenter")
        #expect(track?.isPlaying == true)
        #expect(track?.app == .spotify)
        #expect(track?.duration == 215)
    }

    @Test func parsesPausedTrackAsNotPlaying() {
        let track = ExternalNowPlaying.parse(
            app: .spotify, userInfo: ["Player State": "Paused", "Name": "Song"])
        #expect(track?.isPlaying == false)
        #expect(track?.title == "Song")
    }

    @Test func stoppedStateReturnsNil() {
        let track = ExternalNowPlaying.parse(
            app: .spotify, userInfo: ["Player State": "Stopped", "Name": "Song"])
        #expect(track == nil)
    }

    @Test func missingNameReturnsNil() {
        #expect(
            ExternalNowPlaying.parse(app: .music, userInfo: ["Player State": "Playing"]) == nil)
        #expect(
            ExternalNowPlaying.parse(
                app: .music, userInfo: ["Player State": "Playing", "Name": ""]) == nil)
    }

    @Test func musicUsesTotalTimeForDuration() {
        let track = ExternalNowPlaying.parse(
            app: .music,
            userInfo: [
                "Player State": "Playing", "Name": "Track", "Total Time": NSNumber(value: 180_000),
            ])
        #expect(track?.duration == 180)
        #expect(track?.app == .music)
    }

    @Test func missingArtistDefaultsToEmpty() {
        let track = ExternalNowPlaying.parse(
            app: .spotify, userInfo: ["Player State": "Playing", "Name": "Track"])
        #expect(track?.artist == "")
    }
}

@Suite struct NotchMusicResolverTests {
    private func external(_ title: String, playing: Bool = true) -> ExternalTrack {
        ExternalTrack(app: .spotify, title: title, artist: "A", isPlaying: playing, duration: 100)
    }

    @Test func playingLocalTakesPriorityOverPlayingExternal() {
        let np = NotchMusicResolver.resolve(
            localTitle: "Local Song", localPlaying: true, external: external("Spotify Song"))
        #expect(np?.source == .local)
        #expect(np?.title == "Local Song")
    }

    @Test func playingExternalBeatsPausedLocal() {
        let np = NotchMusicResolver.resolve(
            localTitle: "Paused Local", localPlaying: false, external: external("Spotify Song"))
        #expect(np?.source == .external(.spotify))
        #expect(np?.isPlaying == true)
    }

    @Test func nothingShowsWithoutPriorPlayback() {
        let np = NotchMusicResolver.resolve(
            localTitle: "Paused Local", localPlaying: false,
            external: external("Paused Spotify", playing: false))
        #expect(np == nil)
    }

    @Test func pausedLocalStaysWhenItWasLastActive() {
        let previous = NotchMusicResolver.resolve(
            localTitle: "Paused Local", localPlaying: true, external: nil)
        let np = NotchMusicResolver.resolve(
            localTitle: "Paused Local", localPlaying: false,
            external: external("Paused Spotify", playing: false), previous: previous)
        #expect(np?.source == .local)
        #expect(np?.isPlaying == false)
    }

    @Test func pausedExternalStaysWhenItWasLastActive() {
        let previous = NotchMusicResolver.resolve(
            localTitle: "Paused Local", localPlaying: false, external: external("Spotify Song"))
        #expect(previous?.source == .external(.spotify))
        let np = NotchMusicResolver.resolve(
            localTitle: "Paused Local", localPlaying: false,
            external: external("Spotify Song", playing: false), previous: previous)
        #expect(np?.source == .external(.spotify))
        #expect(np?.isPlaying == false)
        #expect(np?.title == "Spotify Song")
    }

    @Test func pausedExternalYieldsWhenLocalWasLastActive() {
        let previous = NotchMusicResolver.resolve(
            localTitle: "Local Song", localPlaying: true,
            external: external("Spotify Song", playing: false))
        #expect(previous?.source == .local)
        let np = NotchMusicResolver.resolve(
            localTitle: "Local Song", localPlaying: false,
            external: external("Spotify Song", playing: false), previous: previous)
        #expect(np?.source == .local)
    }

    @Test func fallsBackToExternalWhenNoLocal() {
        let np = NotchMusicResolver.resolve(
            localTitle: nil, localPlaying: false, external: external("Spotify Song"))
        #expect(np?.source == .external(.spotify))
        #expect(np?.title == "Spotify Song")
    }

    @Test func emptyLocalTitleFallsBackToExternal() {
        let np = NotchMusicResolver.resolve(
            localTitle: "", localPlaying: false, external: external("Spotify Song"))
        #expect(np?.source == .external(.spotify))
    }

    @Test func nilWhenNothingPlaying() {
        #expect(
            NotchMusicResolver.resolve(localTitle: nil, localPlaying: false, external: nil) == nil)
    }

    @Test func carriesPlayingState() {
        let previous = NotchMusicResolver.resolve(
            localTitle: nil, localPlaying: false, external: external("S"))
        let paused = NotchMusicResolver.resolve(
            localTitle: nil, localPlaying: false, external: external("S", playing: false),
            previous: previous)
        #expect(paused?.isPlaying == false)
    }
}

@Suite struct CollapsedWingSizeTests {
    @Test func addsWingsWhenLiveActivityPresent() {
        let base = CGSize(width: 160, height: 32)
        let withWings = NotchGeometry.collapsedSize(base: base, hasLiveActivity: true)
        #expect(withWings.width == 160 + 2 * NotchGeometry.musicWingWidth)
        #expect(withWings.height == 32)
    }

    @Test func keepsBaseSizeWithoutLiveActivity() {
        let base = CGSize(width: 160, height: 32)
        #expect(NotchGeometry.collapsedSize(base: base, hasLiveActivity: false) == base)
    }
}
