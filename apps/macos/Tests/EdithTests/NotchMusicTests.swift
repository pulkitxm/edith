import CoreGraphics
import Foundation
import Testing

@testable import EdithMenuBar

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

    @Test func parsesSpotifyScriptOutputWithMillisecondDuration() {
        let track = ExternalNowPlaying.parseScriptOutput(
            app: .spotify, output: "Nobody's Son\nSabrina Carpenter\n215000")
        #expect(track?.title == "Nobody's Son")
        #expect(track?.artist == "Sabrina Carpenter")
        #expect(track?.isPlaying == true)
        #expect(track?.duration == 215)
    }

    @Test func parsesMusicScriptOutputWithSecondDuration() {
        let track = ExternalNowPlaying.parseScriptOutput(
            app: .music, output: "Track\nArtist\n180.5")
        #expect(track?.duration == 180.5)
        #expect(track?.app == .music)
    }

    @Test func emptyScriptOutputReturnsNil() {
        #expect(ExternalNowPlaying.parseScriptOutput(app: .spotify, output: "") == nil)
        #expect(ExternalNowPlaying.parseScriptOutput(app: .spotify, output: "\n\n") == nil)
    }
}

@Suite struct NotchMusicResolverTests {
    private func external(_ title: String, playing: Bool = true) -> ExternalTrack {
        ExternalTrack(app: .spotify, title: title, artist: "A", isPlaying: playing, duration: 100)
    }

    @Test func localTakesPriorityOverExternal() {
        let np = NotchMusicResolver.resolve(
            localTitle: "Local Song", localPlaying: true, external: external("Spotify Song"))
        #expect(np?.source == .local)
        #expect(np?.title == "Local Song")
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
        let paused = NotchMusicResolver.resolve(
            localTitle: nil, localPlaying: false, external: external("S", playing: false))
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
