import ArgumentParser
import EdithKit
import Foundation

struct MusicCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "music",
        abstract: "Whatever is playing, and playback control.",
        discussion: """
            `ed music` drives whichever player is actually playing: Spotify, Apple Music
            or Edith's own library. Spotify and Apple Music are driven directly over
            AppleScript, so they work whether or not Edith is running. A player that is
            not already open is never launched.

            Pass `--player builtin|spotify|apple` to force one. `ed music status --json`
            lists every player it can see and marks the active one.
            """,
        subcommands: [
            MusicStatusCommand.self, MusicPlayCommand.self, MusicPauseCommand.self,
            MusicStopCommand.self, MusicToggleCommand.self, MusicNextCommand.self,
            MusicPreviousCommand.self, MusicVolumeCommand.self, MusicPlayersCommand.self,
            MusicListCommand.self, MusicNewFolderCommand.self, MusicMoveCommand.self,
            MusicRenameCommand.self, MusicRemoveCommand.self, MusicPlayTrackCommand.self,
            MusicSeekCommand.self, MusicShuffleCommand.self, MusicRepeatCommand.self,
            MusicRescanCommand.self,
        ],
        defaultSubcommand: MusicStatusCommand.self,
        aliases: ["nowplaying", "np"])
}

struct PlayerChoice: ParsableArguments {
    @Option(name: .long, help: "Force one player: builtin, spotify or apple.")
    var player: String?

    func resolved() throws -> MusicPlayer? {
        guard let player else { return nil }
        return try MusicPlayer.named(player)
    }
}

enum MusicVerb {
    static func act(
        _ action: PlayerAction, forced: MusicPlayer?, json: Bool
    ) async throws {
        let target = try await MusicSession.target(forced: forced)
        try await MusicSession.send(action, to: target.snapshot.player)
        MusicMemory.remember(target.snapshot.player)
        guard !json else {
            CLIOut.json(
                .object([
                    "action": .string(action.pastTense),
                    "player": .string(target.snapshot.player.rawValue),
                    "name": .string(target.snapshot.player.displayName),
                ]))
            return
        }
        CLIOut.out("\(action.pastTense)  (\(target.snapshot.player.displayName))")
    }
}

struct MusicStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "What is playing right now, on whichever player.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute {
            let forced = try choice.resolved()
            guard !json else {
                let players = forced.map { [$0] } ?? MusicPlayer.allCases
                let observed = await MusicSession.snapshots(players)
                let all = forced == nil ? observed : observed + MusicSession.missing(from: observed)
                let active = try? MusicTargeting.resolve(
                    observed, forced: forced, preferred: MusicMemory.last)
                CLIOut.json(MusicSession.report(active: active, all: all))
                return
            }
            CLIOut.out(try await MusicSession.target(forced: forced).snapshot.line)
        }
    }
}

struct MusicPlayersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "players", abstract: "Every player Edith can see, and which is active.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let observed = await MusicSession.snapshots()
            let active = try? MusicTargeting.resolve(observed, preferred: MusicMemory.last)
            guard !json else {
                CLIOut.json(MusicSession.report(active: active, all: observed))
                return
            }
            let rows = observed.map { snapshot in
                [
                    snapshot.player.rawValue,
                    snapshot.isRunning ? "running" : "-",
                    snapshot.isPlaying ? "playing" : (snapshot.hasTrack ? "paused" : "-"),
                    active?.player == snapshot.player ? "active" : "",
                    snapshot.title,
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["PLAYER", "STATE", "PLAYBACK", "", "TRACK"], rows: rows))
        }
    }
}

struct MusicPlayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "play", abstract: "Resume playback on the active player.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute { try await MusicVerb.act(.play, forced: choice.resolved(), json: json) }
    }
}

struct MusicPauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause", abstract: "Pause the active player.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute { try await MusicVerb.act(.pause, forced: choice.resolved(), json: json) }
    }
}

struct MusicStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop the active player and reset its position.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute { try await MusicVerb.act(.stop, forced: choice.resolved(), json: json) }
    }
}

struct MusicToggleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toggle", abstract: "Toggle play and pause.", aliases: ["playpause"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute {
            try await MusicVerb.act(.toggle, forced: choice.resolved(), json: json)
        }
    }
}

struct MusicNextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next", abstract: "Skip to the next track.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute { try await MusicVerb.act(.next, forced: choice.resolved(), json: json) }
    }
}

struct MusicPreviousCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "previous", abstract: "Go back to the previous track.", aliases: ["prev"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute {
            try await MusicVerb.act(.previous, forced: choice.resolved(), json: json)
        }
    }
}

struct MusicVolumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume", abstract: "Set the active player's volume from 0 to 1.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    @Argument(help: "A number between 0 and 1.")
    var level: Double

    func run() async throws {
        try await execute {
            let level = try ArgumentChecks.fraction(self.level, "volume")
            try await MusicVerb.act(.volume(level), forced: choice.resolved(), json: json)
        }
    }
}
