import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct MusicPlayerNamingTests {
    @Test func everySpellingResolvesToItsPlayer() throws {
        #expect(try MusicPlayer.named("spotify") == .spotify)
        #expect(try MusicPlayer.named("SPOTIFY") == .spotify)
        #expect(try MusicPlayer.named("apple") == .apple)
        #expect(try MusicPlayer.named("applemusic") == .apple)
        #expect(try MusicPlayer.named("apple-music") == .apple)
        #expect(try MusicPlayer.named("music") == .apple)
        #expect(try MusicPlayer.named("builtin") == .builtin)
        #expect(try MusicPlayer.named("edith") == .builtin)
    }

    @Test func anUnknownPlayerIsNotFoundAndListsTheRealOnes() {
        do {
            _ = try MusicPlayer.named("winamp")
            Issue.record("naming should have failed")
        } catch let failure as CLIFailure {
            #expect(failure.kind == .notFound)
            #expect(failure.hint?.contains("spotify") == true)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func onlyExternalPlayersHaveAProcessToAddress() {
        #expect(MusicPlayer.builtin.processName == nil)
        #expect(MusicPlayer.spotify.processName == "Spotify")
        #expect(MusicPlayer.apple.processName == "Music")
        #expect(!MusicPlayer.builtin.isExternal)
    }
}

@Suite struct MusicTargetingTests {
    static func snapshot(
        _ player: MusicPlayer, running: Bool = true, playing: Bool = false, title: String = ""
    ) -> PlayerSnapshot {
        PlayerSnapshot(player: player, isRunning: running, isPlaying: playing, title: title)
    }

    @Test func aPlayingPlayerBeatsALoadedButPausedOne() throws {
        let resolved = try MusicTargeting.resolve([
            Self.snapshot(.builtin, playing: false, title: "old.mp3"),
            Self.snapshot(.spotify, playing: true, title: "Meri Kahani"),
        ])
        #expect(resolved.player == .spotify)
    }

    @Test func theBuiltInWinsWhenNothingElseIsPlaying() throws {
        let resolved = try MusicTargeting.resolve([
            Self.snapshot(.builtin, title: "loaded.mp3"),
            Self.snapshot(.spotify, title: "paused song"),
        ])
        #expect(resolved.player == .builtin)
    }

    @Test func aLoadedPlayerBeatsARunningEmptyOne() throws {
        let resolved = try MusicTargeting.resolve([
            Self.snapshot(.builtin, title: ""),
            Self.snapshot(.spotify, title: "something"),
        ])
        #expect(resolved.player == .spotify)
    }

    @Test func onlyTheRunningPlayerIsEverChosen() throws {
        let resolved = try MusicTargeting.resolve([
            Self.snapshot(.builtin, running: false, title: "loaded.mp3"),
            Self.snapshot(.spotify, running: true, title: "song"),
            Self.snapshot(.apple, running: false, playing: true, title: "never"),
        ])
        #expect(resolved.player == .spotify)
    }

    @Test func nothingRunningIsUnavailableRatherThanAGuess() {
        do {
            _ = try MusicTargeting.resolve([
                Self.snapshot(.builtin, running: false),
                Self.snapshot(.spotify, running: false),
                Self.snapshot(.apple, running: false),
            ])
            Issue.record("resolution should have failed")
        } catch let failure as CLIFailure {
            #expect(failure.kind == .unavailable)
            #expect(failure.message.contains("no music player"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func anEmptyObservationIsUnavailable() {
        #expect(throws: CLIFailure.self) { try MusicTargeting.resolve([]) }
    }

    @Test func forcingAPlayerOverridesEvenALoudlyPlayingOne() throws {
        let resolved = try MusicTargeting.resolve(
            [
                Self.snapshot(.builtin, title: "quiet.mp3"),
                Self.snapshot(.spotify, playing: true, title: "loud"),
            ], forced: .builtin)
        #expect(resolved.player == .builtin)
    }

    @Test func forcingAPlayerThatIsNotRunningFailsWithoutLaunchingIt() {
        do {
            _ = try MusicTargeting.resolve(
                [Self.snapshot(.apple, running: false)], forced: .apple)
            Issue.record("resolution should have failed")
        } catch let failure as CLIFailure {
            #expect(failure.kind == .unavailable)
            #expect(failure.message.contains("Apple Music is not running"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func forcingAPlayerThatWasNeverObservedIsNotFound() {
        do {
            _ = try MusicTargeting.resolve([Self.snapshot(.spotify)], forced: .apple)
            Issue.record("resolution should have failed")
        } catch let failure as CLIFailure {
            #expect(failure.kind == .notFound)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func theLastPlayerWeDroveBreaksATieSoPauseThenPlayStaysPut() throws {
        let observed = [
            Self.snapshot(.builtin, title: "loaded.mp3"),
            Self.snapshot(.spotify, title: "just paused"),
        ]
        #expect(try MusicTargeting.resolve(observed).player == .builtin)
        #expect(try MusicTargeting.resolve(observed, preferred: .spotify).player == .spotify)
    }

    @Test func thePreferenceNeverOutranksAPlayerThatIsActuallyPlaying() throws {
        let resolved = try MusicTargeting.resolve(
            [
                Self.snapshot(.builtin, title: "loaded.mp3"),
                Self.snapshot(.spotify, playing: true, title: "loud"),
            ], preferred: .builtin)
        #expect(resolved.player == .spotify)
    }

    @Test func rankingIsOrderedPlayingThenLoadedThenRunning() {
        #expect(MusicTargeting.rank(Self.snapshot(.spotify, running: false)) == 0)
        #expect(MusicTargeting.rank(Self.snapshot(.spotify)) == 1)
        #expect(MusicTargeting.rank(Self.snapshot(.spotify, title: "x")) == 3)
        #expect(MusicTargeting.rank(Self.snapshot(.spotify, playing: true, title: "x")) == 7)
    }
}

@Suite struct MusicScriptTests {
    @Test func theRunningCheckAlwaysComesBeforeTalkingToThePlayer() throws {
        for player in [MusicPlayer.spotify, .apple] {
            let name = try #require(player.processName)
            let snapshot = try #require(PlayerScript.snapshot(player))
            let command = try #require(PlayerScript.command(.pause, on: player))
            for source in [snapshot, command] {
                let guardIndex = try #require(source.range(of: "exists process \"\(name)\""))
                let tellIndex = try #require(
                    source.range(of: "tell application \"\(name)\""))
                #expect(guardIndex.lowerBound < tellIndex.lowerBound)
                #expect(source.contains("System Events"))
                #expect(source.contains("return \"\(PlayerScript.notRunningMarker)\""))
            }
        }
    }

    @Test func theBuiltInPlayerHasNoAppleScriptToRun() {
        #expect(PlayerScript.snapshot(.builtin) == nil)
        #expect(PlayerScript.command(.pause, on: .builtin) == nil)
    }

    @Test func spotifyDurationsAreScaledFromMillisecondsButAppleMusicIsNot() throws {
        let spotify = try #require(PlayerScript.snapshot(.spotify))
        let apple = try #require(PlayerScript.snapshot(.apple))
        #expect(spotify.contains("(duration of current track) / 1000"))
        #expect(apple.contains("(duration of current track)"))
        #expect(!apple.contains("/ 1000"))
    }

    @Test func stopIsARealVerbOnAppleMusicAndARewindOnSpotify() {
        #expect(PlayerScript.verbs(.stop, on: .apple) == ["stop"])
        #expect(
            PlayerScript.verbs(.stop, on: .spotify) == ["pause", "set player position to 0"])
    }

    @Test func playPauseAndToggleAreThreeDifferentVerbs() {
        #expect(PlayerScript.verbs(.play, on: .spotify) == ["play"])
        #expect(PlayerScript.verbs(.pause, on: .spotify) == ["pause"])
        #expect(PlayerScript.verbs(.toggle, on: .spotify) == ["playpause"])
    }

    @Test func volumeIsClampedAndSentAsAPercentage() {
        #expect(PlayerScript.verbs(.volume(0.4), on: .spotify) == ["set sound volume to 40"])
        #expect(PlayerScript.verbs(.volume(-1), on: .spotify) == ["set sound volume to 0"])
        #expect(PlayerScript.verbs(.volume(9), on: .spotify) == ["set sound volume to 100"])
    }

    @Test func aNotRunningAnswerYieldsAnIdlePlayerRatherThanAGuess() {
        let parsed = PlayerScript.parse(PlayerScript.notRunningMarker, player: .spotify)
        #expect(!parsed.isRunning)
        #expect(!parsed.isPlaying)
        #expect(!parsed.hasTrack)
    }

    @Test func aWellFormedAnswerBecomesASnapshot() {
        let fields = [
            "ok", "playing", "Meri Kahani", "Atif Aslam", "45.6", "192.9", "80",
        ]
        let parsed = PlayerScript.parse(
            fields.joined(separator: PlayerScript.separator), player: .spotify)
        #expect(parsed.isRunning)
        #expect(parsed.isPlaying)
        #expect(parsed.title == "Meri Kahani")
        #expect(parsed.artist == "Atif Aslam")
        #expect(parsed.elapsedSeconds == 45.6)
        #expect(parsed.durationSeconds == 192.9)
        #expect(parsed.volume == 0.8)
    }

    @Test func aTruncatedAnswerStillReportsThePlayerAsRunning() {
        let parsed = PlayerScript.parse("ok\u{1F}paused", player: .apple)
        #expect(parsed.isRunning)
        #expect(!parsed.hasTrack)
    }

    @Test func aPausedAnswerIsNotReportedAsPlaying() {
        let fields = ["ok", "paused", "Song", "", "1", "2", "50"]
        let parsed = PlayerScript.parse(
            fields.joined(separator: PlayerScript.separator), player: .apple)
        #expect(!parsed.isPlaying)
        #expect(parsed.hasTrack)
    }
}

@Suite struct AppleScriptFailureTests {
    @Test func aDeniedAutomationPromptNamesTheSettingToChange() {
        let failure = AppleScriptHost.failure(
            from: "execution error: Not authorized to send Apple events to Spotify. (-1743)")
        #expect(failure.kind == .unavailable)
        #expect(failure.hint?.contains("Automation") == true)
    }

    @Test func aMissingApplicationIsReportedAsNotRunning() {
        let failure = AppleScriptHost.failure(from: "execution error: (-600)")
        #expect(failure.kind == .unavailable)
        #expect(failure.message.contains("not running"))
    }

    @Test func anythingElseKeepsTheOriginalComplaintAsTheHint() {
        let failure = AppleScriptHost.failure(from: "execution error: something odd (-1728)")
        #expect(failure.kind == .unavailable)
        #expect(failure.hint?.contains("-1728") == true)
    }
}

@Suite struct MusicSessionTests {
    @Test func theBuiltInStopBothPausesAndRewinds() {
        #expect(
            MusicSession.builtinCommands(.stop) == [
                BuiltinCommand("pause"), BuiltinCommand("seek", value: 0),
            ])
    }

    @Test func everyActionMapsOntoAVerbTheAppAlreadyUnderstands() {
        let known: Set<String> = [
            "playPause", "pause", "resume", "next", "previous", "seek", "volume",
        ]
        let actions: [PlayerAction] = [
            .play, .pause, .stop, .toggle, .next, .previous, .volume(0.5),
        ]
        for action in actions {
            for command in MusicSession.builtinCommands(action) {
                #expect(known.contains(command.action), "\(command.action) is not handled")
            }
        }
    }

    @Test func playAndPauseAreNeverTheSameCommandAsToggle() {
        #expect(MusicSession.builtinCommands(.play) != MusicSession.builtinCommands(.toggle))
        #expect(MusicSession.builtinCommands(.pause) != MusicSession.builtinCommands(.toggle))
        #expect(MusicSession.builtinCommands(.pause) != MusicSession.builtinCommands(.play))
    }

    @Test func volumeTravelsAsAFraction() {
        #expect(MusicSession.builtinCommands(.volume(0.25)).first?.value == 0.25)
        #expect(
            MusicSession.builtinCommands(.volume(0.25)).first?.userInfo["value"] as? Double
                == 0.25)
    }

    @Test func theBuiltInReplyBecomesASnapshotWithJustTheFileName() {
        let snapshot = MusicSession.decodeBuiltin([
            "track": "albums/Gal ban gyi.mp3", "isPlaying": true, "elapsed": 103.0,
            "duration": 360.0, "volume": 0.4,
        ])
        #expect(snapshot.player == .builtin)
        #expect(snapshot.isRunning)
        #expect(snapshot.title == "Gal ban gyi.mp3")
        #expect(snapshot.volume == 0.4)
    }

    @Test func anEmptyBuiltInReplyIsRunningButIdle() {
        let snapshot = MusicSession.decodeBuiltin([:])
        #expect(snapshot.isRunning)
        #expect(!snapshot.hasTrack)
    }

    @Test func theReportNamesEveryPlayerAndTheActiveOne() {
        let all = MusicPlayer.allCases.map { PlayerSnapshot(player: $0) }
        let active = PlayerSnapshot(player: .spotify, isRunning: true, title: "x")
        guard case let .object(fields) = MusicSession.report(active: active, all: all) else {
            Issue.record("report should be an object")
            return
        }
        #expect(Set(fields.keys) == ["active", "player", "players"])
        #expect(fields["player"] == .string("spotify"))
        guard case let .array(players)? = fields["players"] else {
            Issue.record("players should be an array")
            return
        }
        #expect(players.count == MusicPlayer.allCases.count)
    }

    @Test func aReportWithNoActivePlayerSaysSoRatherThanOmittingTheKey() {
        guard
            case let .object(fields) = MusicSession.report(
                active: nil, all: MusicPlayer.allCases.map { PlayerSnapshot(player: $0) })
        else {
            Issue.record("report should be an object")
            return
        }
        #expect(fields["active"] == .null)
        #expect(fields["player"] == .null)
    }
}

@Suite struct PlayerSnapshotTextTests {
    @Test func everyStatusLineNamesThePlayerItCameFrom() {
        for player in MusicPlayer.allCases {
            let loaded = PlayerSnapshot(
                player: player, isRunning: true, isPlaying: true, title: "Song",
                artist: "Artist", elapsedSeconds: 65, durationSeconds: 180)
            let idle = PlayerSnapshot(player: player, isRunning: true)
            #expect(loaded.line.contains("(\(player.displayName))"))
            #expect(idle.line.contains("(\(player.displayName))"))
        }
    }

    @Test func theClockIsMinutesAndSeconds() {
        let snapshot = PlayerSnapshot(
            player: .spotify, isRunning: true, isPlaying: true, title: "Song",
            elapsedSeconds: 65, durationSeconds: 185)
        #expect(snapshot.line.contains("1:05/3:05"))
    }

    @Test func aTrackWithNoArtistDoesNotLeaveADanglingSeparator() {
        let snapshot = PlayerSnapshot(
            player: .builtin, isRunning: true, title: "Gal ban gyi.mp3", elapsedSeconds: 0,
            durationSeconds: 0)
        #expect(snapshot.line == "paused  Gal ban gyi.mp3  0:00/0:00  (Edith)")
    }

    @Test func nonFiniteTimesNeverCrashTheFormatter() {
        let snapshot = PlayerSnapshot(
            player: .spotify, isRunning: true, title: "Song",
            elapsedSeconds: .nan, durationSeconds: .infinity)
        #expect(snapshot.line.contains("0:00"))
    }

    @Test func theSnapshotJSONKeepsAStableKeySet() {
        guard case let .object(fields) = PlayerSnapshot(player: .spotify).json else {
            Issue.record("snapshot should be an object")
            return
        }
        #expect(
            Set(fields.keys) == [
                "player", "name", "running", "isPlaying", "title", "artist",
                "elapsedSeconds", "durationSeconds", "volume",
            ])
    }
}

@Suite struct MusicCommandEndToEndTests {
    @Test func pauseTargetsSpotifyWhenItIsPlayingAndTheLibraryIsMerelyLoaded() async throws {
        try await CLIProbe.inWorld { world in
            world.helperRunning(true)
            world.shared.set(true, forKey: MusicSession.builtinExtensionKey)
            world.answers { _ in
                ["track": "Gal ban gyi.mp3", "isPlaying": false, "elapsed": 103.0]
            }
            world.players([
                .spotify: PlayerSnapshot(
                    player: .spotify, isRunning: true, isPlaying: true, title: "Meri Kahani",
                    artist: "Atif Aslam"),
                .apple: PlayerSnapshot(player: .apple),
            ])
            let result = await CLIProbe.capture(["music", "pause"])
            #expect(result.code == 0)
            #expect(result.stdout == "paused  (Spotify)\n")
            #expect(!world.postedNames().contains(IPC.Name.musicCommand.rawValue))
            #expect(
                world.recordedScripts().contains {
                    $0.contains("tell application \"Spotify\"") && $0.contains("\tpause")
                })
            #expect(world.recordedScripts().allSatisfy { !$0.contains("\"Music\"\n\tpause") })
        }
    }

    @Test func pauseTargetsTheLibraryWhenNoExternalPlayerIsRunning() async throws {
        try await CLIProbe.inWorld { world in
            world.helperRunning(true)
            world.shared.set(true, forKey: MusicSession.builtinExtensionKey)
            world.answers { _ in ["track": "Gal ban gyi.mp3", "isPlaying": true] }
            world.players([:])
            let result = await CLIProbe.capture(["music", "pause"])
            #expect(result.code == 0)
            #expect(result.stdout == "paused  (Edith)\n")
            #expect(world.postedNames().contains(IPC.Name.musicCommand.rawValue))
        }
    }

    @Test func statusWithNoPlayerAtAllExitsUnavailable() async throws {
        try await CLIProbe.inWorld { world in
            world.helperRunning(false)
            world.players([:])
            let result = await CLIProbe.capture(["music", "status"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("no music player is running"))
        }
    }

    @Test func statusJSONIsOneDocumentListingEveryPlayer() async throws {
        try await CLIProbe.inWorld { world in
            world.players([
                .spotify: PlayerSnapshot(
                    player: .spotify, isRunning: true, isPlaying: true, title: "Meri Kahani")
            ])
            let result = await CLIProbe.capture(["music", "status", "--json"])
            #expect(result.code == 0)
            let object = try #require(result.object)
            #expect(Set(object.keys) == ["active", "player", "players"])
            #expect(object["player"] as? String == "spotify")
            #expect((object["players"] as? [Any])?.count == MusicPlayer.allCases.count)
        }
    }

    @Test func aForcedPlayerThatIsNotRunningIsNeverLaunched() async throws {
        try await CLIProbe.inWorld { world in
            world.players([:])
            let result = await CLIProbe.capture(["music", "play", "--player", "apple"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("Apple Music is not running"))
            for script in world.recordedScripts() {
                #expect(script.contains("exists process \"Music\""))
            }
        }
    }

    @Test func anUnknownForcedPlayerIsNotFound() async {
        let result = await CLIProbe.run(["music", "pause", "--player", "winamp"])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stdout.isEmpty)
    }

    @Test func nowplayingAndNpAreTheSameCommandAsMusic() throws {
        for name in ["music", "nowplaying", "np"] {
            let parsed = try EdRoot.parseAsRoot([name, "status"])
            #expect(type(of: parsed).configuration.commandName == "status")
        }
    }

    @Test func volumeOutsideZeroToOneIsRejectedBeforeAnyPlayerIsTouched() async throws {
        try await CLIProbe.inWorld { world in
            world.players([
                .spotify: PlayerSnapshot(player: .spotify, isRunning: true, title: "x")
            ])
            let result = await CLIProbe.capture(["music", "volume", "5"])
            #expect(result.code == ExitCodes.usage)
            #expect(result.stderr.contains("between 0 and 1"))
            #expect(world.recordedScripts().isEmpty)
        }
    }
}
