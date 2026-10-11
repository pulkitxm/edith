import ArgumentParser
import EdithExtensionCommands
import Foundation
import Testing

@testable import MusicExtension

@Suite struct MusicParserIsolationTests {
    private static var leaves: [(String, [String], ParsableCommand.Type)] {
        [
            ("status", [], MusicStatusCommand.self),
            ("play", [], MusicPlayCommand.self),
            ("pause", [], MusicPauseCommand.self),
            ("stop", [], MusicStopCommand.self),
            ("toggle", [], MusicToggleCommand.self),
            ("next", [], MusicNextCommand.self),
            ("previous", [], MusicPreviousCommand.self),
            ("volume", ["0.25"], MusicVolumeCommand.self),
            ("players", [], MusicPlayersCommand.self),
            ("open-current", [], MusicOpenCurrentCommand.self),
            ("reveal-current", [], MusicRevealCurrentCommand.self),
            ("library", ["/tmp/synthetic-library"], MusicLibraryFolderCommand.self),
            ("ls", [], MusicListCommand.self),
            ("mkdir", ["Synthetic"], MusicNewFolderCommand.self),
            ("mv", ["synthetic.wav", "Synthetic"], MusicMoveCommand.self),
            ("rename", ["synthetic.wav", "Renamed"], MusicRenameCommand.self),
            ("rm", ["synthetic.wav"], MusicRemoveCommand.self),
            ("start", ["synthetic.wav"], MusicPlayTrackCommand.self),
            ("seek", ["0.5"], MusicSeekCommand.self),
            ("shuffle", [], MusicShuffleCommand.self),
            ("repeat", [], MusicRepeatCommand.self),
            ("rescan", [], MusicRescanCommand.self),
            ("favorite", ["synthetic.wav"], MusicFavoriteCommand.self),
            ("unfavorite", ["synthetic.wav"], MusicUnfavoriteCommand.self),
            ("reveal", ["synthetic.wav"], MusicRevealCommand.self),
            ("open", [], MusicOpenLibraryCommand.self),
        ]
    }

    @Test func completeCommandTreeParsesOffMainActorWithoutRunning() async throws {
        try await Task.detached {
            #expect(MusicCommand.configuration.aliases == ["nowplaying", "np"])
            #expect(try MusicCommand.parseAsRoot([]) is MusicStatusCommand)
            #expect(MusicCommand.configuration.subcommands.count == Self.leaves.count)
            for (name, arguments, expected) in Self.leaves {
                let parsed = try MusicCommand.parseAsRoot([name] + arguments + ["--json"])
                #expect(type(of: parsed) == expected)
                for alias in expected.configuration.aliases {
                    let alternate = try MusicCommand.parseAsRoot([alias] + arguments + ["--json"])
                    #expect(type(of: alternate) == expected)
                }
            }
        }.value
    }

    @Test func distinctLibraryFlagsAndValuesAreRetained() throws {
        let list = try MusicListCommand.parse([
            "Albums", "--folders", "--recursive", "--search", "one", "--json",
        ])
        #expect(list.folder == "Albums" && list.folders && list.recursive && list.json)
        #expect(list.search == "one")
        let mkdir = try MusicNewFolderCommand.parse(["Focus", "--under", "Albums", "--json"])
        #expect(mkdir.name == "Focus" && mkdir.under == "Albums" && mkdir.json)
        let rename = try MusicRenameCommand.parse(["Albums", "Focus", "--folder", "--json"])
        #expect(rename.target == "Albums" && rename.name == "Focus" && rename.folder && rename.json)
        let remove = try MusicRemoveCommand.parse(["Albums", "--folder", "--yes", "--json"])
        #expect(remove.target == "Albums" && remove.folder && remove.yes && remove.json)
        #expect(!(try MusicRemoveCommand.parse(["synthetic.wav"])).yes)
        let start = try MusicPlayTrackCommand.parse(["Albums", "--folder", "--json"])
        #expect(start.target == "Albums" && start.folder && start.json)
        let volume = try MusicVolumeCommand.parse(["0.25", "--player", "builtin", "--json"])
        #expect(volume.level == 0.25 && volume.choice.player == "builtin" && volume.json)
        let seek = try MusicSeekCommand.parse(["0.5", "--json"])
        #expect(seek.position == 0.5 && seek.json)
        #expect(try MusicShuffleCommand.parse(["on"]).state == "on")
        #expect(try MusicRepeatCommand.parse(["off"]).state == "off")
    }

    @Test func playerChoicePreservesValidationAndAliases() throws {
        #expect(try PlayerChoice.parse([]).resolved() == nil)
        for (name, expected) in [
            ("builtin", MusicPlayer.builtin), ("edith", .builtin), ("spotify", .spotify),
            ("apple", .apple), ("itunes", .apple),
        ] {
            #expect(try PlayerChoice.parse(["--player", name]).resolved() == expected)
        }
        #expect(throws: CLIFailure.self) {
            try PlayerChoice.parse(["--player", "missing"]).resolved()
        }
        #expect(throws: (any Error).self) { try MusicCommand.parseAsRoot(["missing"]) }
        #expect(throws: (any Error).self) { try MusicVolumeCommand.parse(["invalid"]) }
        #expect(throws: (any Error).self) { try MusicRemoveCommand.parse([]) }
    }
}
