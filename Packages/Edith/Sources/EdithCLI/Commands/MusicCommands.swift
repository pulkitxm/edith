import AppKit
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
            Reads nothing until a subcommand runs. Does not change anything by itself.
            """,
        subcommands: [
            MusicStatusCommand.self, MusicPlayCommand.self, MusicPauseCommand.self,
            MusicStopCommand.self, MusicToggleCommand.self, MusicNextCommand.self,
            MusicPreviousCommand.self, MusicVolumeCommand.self, MusicPlayersCommand.self,
            MusicOpenCurrentCommand.self, MusicRevealCurrentCommand.self,
            MusicLibraryFolderCommand.self, MusicListCommand.self, MusicNewFolderCommand.self,
            MusicMoveCommand.self,
            MusicRenameCommand.self, MusicRemoveCommand.self, MusicPlayTrackCommand.self,
            MusicSeekCommand.self, MusicShuffleCommand.self, MusicRepeatCommand.self,
            MusicRescanCommand.self, MusicFavoriteCommand.self, MusicUnfavoriteCommand.self,
            MusicRevealCommand.self, MusicOpenLibraryCommand.self,
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

enum MusicCurrentVerb {
    static func act(
        _ operation: MusicCurrentOperation, forced: MusicPlayer?, json: Bool
    ) async throws {
        let selected = try await MusicSession.target(forced: forced).snapshot
        let target = MusicCurrentTarget(player: selected.player, trackPath: selected.trackPath)
        let result: MusicCurrentOperationResult
        do {
            result = try await MainActor.run {
                try MusicCurrentOperationExecution.perform(
                    operation, target: target,
                    openPlayer: { player in
                        if player == .builtin {
                            MainApp.open(section: "music")
                            return true
                        }
                        guard let bundleIdentifier = player.bundleIdentifier,
                            let url = NSWorkspace.shared.urlForApplication(
                                withBundleIdentifier: bundleIdentifier)
                        else { return false }
                        NSWorkspace.shared.openApplication(
                            at: url, configuration: NSWorkspace.OpenConfiguration())
                        return true
                    },
                    revealTrack: { trackPath in
                        MusicReveal.request(trackPath: trackPath)
                        return true
                    })
            }
        } catch let error as MusicCurrentOperationError {
            throw error.cliFailure
        }
        MusicMemory.remember(result.player)
        guard !json else {
            CLIOut.json(
                .object([
                    "operation": .string(result.operation.rawValue),
                    "player": .string(result.player.rawValue),
                    "name": .string(result.player.displayName),
                    "trackPath": .optional(result.trackPath),
                    "revealed": .bool(result.revealed),
                ]))
            return
        }
        if result.revealed, let trackPath = result.trackPath {
            CLIOut.out("revealed \(trackPath)")
        } else {
            CLIOut.out("opened \(result.player.displayName)")
        }
    }
}

struct MusicStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "What is playing right now, on whichever player.",
        discussion: """
            Prints one line about whatever is playing, on whichever player.

            Reads the current state. Does not change it.

            ed music status
            ed music status --json
            """, )

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
        commandName: "players", abstract: "List every player Edith can see, and which is active.",
        discussion: """
            Lists every player Edith can see, what state each is in, and which one the
            other commands would target.

            Changes the state this command names.

            ed music players
            ed music players --json
            """, )

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

struct MusicOpenCurrentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open-current", abstract: "Open the active music player.",
        discussion: """
            Opens whichever player `ed music status` considers active.

            Changes the state this command names.

            ed music open-current
            ed music open-current --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute {
            try await MusicCurrentVerb.act(
                .openCurrent, forced: choice.resolved(), json: json)
        }
    }
}

struct MusicRevealCurrentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reveal-current",
        abstract: "Reveal the current library track or open its player.",
        discussion: """
            Opens Edith's Music page at the folder containing the track currently loaded
            in the built-in library player.

            Changes the state this command names.

            ed music reveal-current
            ed music reveal-current --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute {
            try await MusicCurrentVerb.act(
                .revealCurrent, forced: choice.resolved(), json: json)
        }
    }
}

struct MusicPlayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "play", abstract: "Start playback on the active player.",
        discussion: """
            Resumes playback on the active player.

            Changes the state this command names.

            ed music play
            ed music play --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute { try await MusicVerb.act(.play, forced: choice.resolved(), json: json) }
    }
}

struct MusicPauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause", abstract: "Pause the active player.",
        discussion: """
            Pauses the active player.

            Changes the container by freezing its processes.

            ed music pause
            ed music pause --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute { try await MusicVerb.act(.pause, forced: choice.resolved(), json: json) }
    }
}

struct MusicStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop the active player and reset its position.",
        discussion: """
            Stops the active player and resets its position to the start of the track.

            Changes the target by stopping it.

            ed music stop
            ed music stop --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute { try await MusicVerb.act(.stop, forced: choice.resolved(), json: json) }
    }
}

struct MusicToggleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toggle", abstract: "Toggle play and pause.",
        discussion: """
            Toggles play and pause on the active player.

            Changes the state this command names.

            ed music toggle
            ed music toggle --json
            """, aliases: ["playpause"])

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
        commandName: "next", abstract: "Skip to the next track.",
        discussion: """
            Skips to the next track.

            Reads the one question worth asking now. Does not change the queue.

            ed music next
            ed music next --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var choice: PlayerChoice

    func run() async throws {
        try await execute { try await MusicVerb.act(.next, forced: choice.resolved(), json: json) }
    }
}

struct MusicPreviousCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "previous", abstract: "Go back to the previous track.",
        discussion: """
            Goes back to the previous track.

            Changes the state this command names.

            ed music previous
            ed music previous --json
            """, aliases: ["prev"])

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
        commandName: "volume", abstract: "Set the active player's volume from 0 to 1.",
        discussion: """
            Sets the active player's volume as a fraction from 0 to 1.

            Changes the system output volume.

            ed music volume 0.5
            ed music volume 0.5 --json
            """, )

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
