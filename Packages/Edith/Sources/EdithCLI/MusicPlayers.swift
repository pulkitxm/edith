import EdithKit
import Foundation

extension MusicPlayer {
    public static func named(_ text: String) throws -> MusicPlayer {
        guard let found = resolveName(text) else {
            throw CLIFailure.notFound(
                "no player named \(text)",
                hint: "players: " + MusicPlayer.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return found
    }
}

extension PlayerAction {
    public var pastTense: String {
        switch self {
        case .play: "playing"
        case .pause: "paused"
        case .stop: "stopped"
        case .toggle: "toggled"
        case .next: "skipped"
        case .previous: "went back"
        case .volume: "volume set"
        }
    }
}

extension PlayerSnapshot {
    public var json: JSONValue {
        .object([
            "player": .string(player.rawValue),
            "name": .string(player.displayName),
            "running": .bool(isRunning),
            "isPlaying": .bool(isPlaying),
            "title": title.isEmpty ? .null : .string(title),
            "artist": artist.isEmpty ? .null : .string(artist),
            "elapsedSeconds": .double(elapsedSeconds),
            "durationSeconds": .double(durationSeconds),
            "volume": .optional(volume),
            "trackPath": .optional(trackPath),
        ])
    }

    public var line: String {
        let state = isPlaying ? "playing" : (hasTrack ? "paused" : "idle")
        guard hasTrack else { return "\(state)  (\(player.displayName))" }
        let credit = artist.isEmpty ? "" : "  \(artist)"
        return
            "\(state)  \(title)\(credit)  \(clock(elapsedSeconds))/\(clock(durationSeconds))"
            + "  (\(player.displayName))"
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension MusicTransportError {
    public var cliFailure: CLIFailure {
        switch self {
        case .playerNotRunning(let player):
            .unavailable(
                "\(player.displayName) is not running",
                hint: player == .builtin
                    ? "open Edith and turn the Music extension on"
                    : "open \(player.displayName), then retry")
        case .noPlayer:
            .unavailable(
                "no music player is running",
                hint: "open Spotify or Apple Music, or turn on Edith's Music extension")
        }
    }
}

extension MusicCurrentOperationError {
    public var cliFailure: CLIFailure {
        switch self {
        case .openFailed(let player):
            .unavailable(
                "could not open \(player.displayName)",
                hint: player == .builtin
                    ? "install Edith, then retry"
                    : "install \(player.displayName), then retry")
        case .revealFailed(let path):
            .unavailable(
                "could not reveal \(path)",
                hint: "check that the current track still exists, then retry")
        }
    }
}
