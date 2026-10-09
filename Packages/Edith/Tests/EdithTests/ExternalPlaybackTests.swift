import AppKit
import EdithKit
import Testing

@testable import EdithHelper

@Suite struct ExternalPlaybackTests {
    @Test func commandsUseTheCorrectPlayerPropertiesAndClampFractions() {
        #expect(
            ExternalPlaybackScript.command(["action": "seek", "value": 2.0], app: .spotify)
                == "set player position to ((duration of current track) / 1000) * 1.0")
        #expect(
            ExternalPlaybackScript.command(["action": "seek", "value": 0.5], app: .music)
                == "set player position to ((duration of current track)) * 0.5")
        #expect(
            ExternalPlaybackScript.command(["action": "volume", "value": -1.0], app: .spotify)
                == "set sound volume to 0")
        #expect(
            ExternalPlaybackScript.command(["action": "shuffle", "value": true], app: .music)
                == "set shuffle enabled to true")
        #expect(
            ExternalPlaybackScript.command(["action": "loop", "value": false], app: .music)
                == "set song repeat to off")
        #expect(
            ExternalPlaybackScript.command(["action": "loop", "value": true], app: .spotify)
                == "set repeating to true")
        #expect(
            ExternalPlaybackScript.command(["action": "seek", "value": Double.nan], app: .spotify)
                == nil)
        #expect(
            ExternalPlaybackScript.command(
                ["action": "volume", "value": Double.infinity], app: .music) == nil)
        #expect(ExternalPlaybackScript.command(["action": "unknown"], app: .spotify) == nil)
    }

    @Test func snapshotsParseTimingVolumeAndCapabilities() throws {
        let result = NSAppleEventDescriptor.list()
        let values: [NSAppleEventDescriptor] = [
            .init(string: "Sample track"), .init(string: "Sample artist"), .init(boolean: true),
            .init(double: 240), .init(double: 80), .init(int32: 65),
            .init(boolean: true), .init(boolean: false), .init(boolean: false),
            .init(boolean: true),
        ]
        for (index, value) in values.enumerated() { result.insert(value, at: index + 1) }
        var playback = try #require(ExternalPlaybackScript.parse(result, app: .spotify))
        #expect(playback.track.duration == 240)
        #expect(playback.volume == 0.65)
        #expect(playback.shuffling)
        #expect(!playback.canShuffle)
        #expect(playback.canRepeat)
        let sample = playback.sampledAt
        #expect(playback.elapsed(at: sample.addingTimeInterval(3)) == 83)
        #expect(playback.elapsed(at: sample.addingTimeInterval(300)) == 240)
        playback.track.isPlaying = false
        #expect(playback.elapsed(at: sample.addingTimeInterval(3)) == 80)
        #expect(ExternalPlaybackScript.parse(.list(), app: .music) == nil)
    }

    @Test func scriptsCompileAgainstInstalledPlayerDictionaries() throws {
        for app in ExternalApp.allCases {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil
            else { continue }
            for command in [nil, "set song repeat to all"].map({
                app == .spotify && $0 != nil ? "set repeating to true" : $0
            }) {
                let script = try #require(
                    NSAppleScript(source: ExternalPlaybackScript.source(app: app, command: command))
                )
                var error: NSDictionary?
                let compiled = script.compileAndReturnError(&error)
                #expect(compiled, "\(error?.description ?? "compile failed")")
            }
        }
    }

    @MainActor @Test func notchControlsUseReportedStateAndTiming() {
        let track = ExternalTrack(
            app: .spotify, title: "Sample", artist: "Artist", isPlaying: false, duration: 200)
        let controller = NotchShelfController(
            nowPlaying: .init(
                source: .external(.spotify), title: track.title,
                artist: track.artist, isPlaying: false), startsServices: false,
            playback: .init(
                track: track, position: 50, volume: 0.8, shuffling: true,
                repeating: false, canShuffle: true, canRepeat: false))
        #expect(controller.nowPlayingSeekable)
        #expect(controller.nowPlayingProgress() == 0.25)
        #expect(controller.nowPlayingVolume == 0.8)
        #expect(controller.nowPlayingShuffle == true)
        #expect(controller.nowPlayingRepeat == nil)
    }
}
