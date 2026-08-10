import AppKit
import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@MainActor
@Suite struct MusicKeyCommandTests {
    init() {
        _ = NSApplication.shared
    }

    private final class Recorder {
        var playPauseCount = 0
        var seeks: [TimeInterval] = []
        var volumes: [Double] = []
    }

    private func handlers(_ recorder: Recorder) -> MusicKeyCommand.Handlers {
        MusicKeyCommand.Handlers(
            playPause: { recorder.playPauseCount += 1 },
            seekBy: { recorder.seeks.append($0) },
            volumeBy: { recorder.volumes.append($0) })
    }

    @Test func spaceTriggersPlayPauseAndConsumes() {
        let recorder = Recorder()
        let consumed = MusicKeyCommand.handle(
            keyCode: 49, modifiers: [], active: true, handlers(recorder))
        #expect(consumed)
        #expect(recorder.playPauseCount == 1)
        #expect(recorder.seeks.isEmpty)
        #expect(recorder.volumes.isEmpty)
    }

    @Test func leftArrowSeeksBackwardBySeekStep() {
        let recorder = Recorder()
        let consumed = MusicKeyCommand.handle(
            keyCode: 123, modifiers: [], active: true, handlers(recorder))
        #expect(consumed)
        #expect(recorder.seeks == [-MusicKeyCommand.seekStep])
    }

    @Test func rightArrowSeeksForwardBySeekStep() {
        let recorder = Recorder()
        let consumed = MusicKeyCommand.handle(
            keyCode: 124, modifiers: [], active: true, handlers(recorder))
        #expect(consumed)
        #expect(recorder.seeks == [MusicKeyCommand.seekStep])
    }

    @Test func downArrowLowersVolumeByVolumeStep() {
        let recorder = Recorder()
        let consumed = MusicKeyCommand.handle(
            keyCode: 125, modifiers: [], active: true, handlers(recorder))
        #expect(consumed)
        #expect(recorder.volumes == [-MusicKeyCommand.volumeStep])
    }

    @Test func upArrowRaisesVolumeByVolumeStep() {
        let recorder = Recorder()
        let consumed = MusicKeyCommand.handle(
            keyCode: 126, modifiers: [], active: true, handlers(recorder))
        #expect(consumed)
        #expect(recorder.volumes == [MusicKeyCommand.volumeStep])
    }

    @Test func inactiveIgnoresEverything() {
        let recorder = Recorder()
        let consumed = MusicKeyCommand.handle(
            keyCode: 49, modifiers: [], active: false, handlers(recorder))
        #expect(!consumed)
        #expect(recorder.playPauseCount == 0)
    }

    @Test(arguments: [
        NSEvent.ModifierFlags.command, .option, .control, [.command, .option],
    ])
    func modifierKeysPassThrough(modifiers: NSEvent.ModifierFlags) {
        let recorder = Recorder()
        let consumed = MusicKeyCommand.handle(
            keyCode: 49, modifiers: modifiers, active: true, handlers(recorder))
        #expect(!consumed)
        #expect(recorder.playPauseCount == 0)
        #expect(recorder.seeks.isEmpty)
        #expect(recorder.volumes.isEmpty)
    }

    @Test(arguments: [UInt16(0), 36, 53, 122])
    func unhandledKeycodesReturnFalse(keyCode: UInt16) {
        let recorder = Recorder()
        let consumed = MusicKeyCommand.handle(
            keyCode: keyCode, modifiers: [], active: true, handlers(recorder))
        #expect(!consumed)
        #expect(recorder.playPauseCount == 0)
        #expect(recorder.seeks.isEmpty)
        #expect(recorder.volumes.isEmpty)
    }
}

@Suite struct ExternalAppMappingTests {
    @Test func coversExactlySpotifyAndMusic() {
        #expect(ExternalApp.allCases == [.spotify, .music])
    }

    @Test func spotifyMapping() {
        #expect(ExternalApp.spotify.bundleID == "com.spotify.client")
        #expect(ExternalApp.spotify.notificationName == "com.spotify.client.PlaybackStateChanged")
        #expect(ExternalApp.spotify.processName == "Spotify")
        #expect(ExternalApp.spotify.displayName == "Spotify")
    }

    @Test func musicMapping() {
        #expect(ExternalApp.music.bundleID == "com.apple.Music")
        #expect(ExternalApp.music.notificationName == "com.apple.Music.playerInfo")
        #expect(ExternalApp.music.processName == "Music")
        #expect(ExternalApp.music.displayName == "Apple Music")
    }

    @Test func externalTrackEqualityComparesAllFields() {
        let track = ExternalTrack(
            app: .spotify, title: "T", artist: "A", isPlaying: true, duration: 100)
        #expect(
            track
                == ExternalTrack(
                    app: .spotify, title: "T", artist: "A", isPlaying: true, duration: 100))
        #expect(
            track
                != ExternalTrack(
                    app: .music, title: "T", artist: "A", isPlaying: true, duration: 100))
        #expect(
            track
                != ExternalTrack(
                    app: .spotify, title: "T2", artist: "A", isPlaying: true, duration: 100))
        #expect(
            track
                != ExternalTrack(
                    app: .spotify, title: "T", artist: "A2", isPlaying: true, duration: 100))
        #expect(
            track
                != ExternalTrack(
                    app: .spotify, title: "T", artist: "A", isPlaying: false, duration: 100))
        #expect(
            track
                != ExternalTrack(
                    app: .spotify, title: "T", artist: "A", isPlaying: true, duration: 99))
    }
}
