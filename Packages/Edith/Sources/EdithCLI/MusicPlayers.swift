import Foundation

public enum MusicPlayer: String, CaseIterable, Sendable {
    case builtin
    case spotify
    case apple

    public var displayName: String {
        switch self {
        case .builtin: return "Edith"
        case .spotify: return "Spotify"
        case .apple: return "Apple Music"
        }
    }

    public var processName: String? {
        switch self {
        case .builtin: return nil
        case .spotify: return "Spotify"
        case .apple: return "Music"
        }
    }

    public var isExternal: Bool { processName != nil }

    public static let spellings: [String: MusicPlayer] = [
        "builtin": .builtin, "built-in": .builtin, "edith": .builtin, "internal": .builtin,
        "spotify": .spotify,
        "apple": .apple, "applemusic": .apple, "apple-music": .apple, "music": .apple,
        "itunes": .apple,
    ]

    public static func named(_ text: String) throws -> MusicPlayer {
        guard let found = spellings[text.lowercased()] else {
            throw CLIFailure.notFound(
                "no player named \(text)",
                hint: "players: " + MusicPlayer.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return found
    }
}

public enum PlayerAction: Equatable, Sendable {
    case play
    case pause
    case stop
    case toggle
    case next
    case previous
    case volume(Double)

    public var pastTense: String {
        switch self {
        case .play: return "playing"
        case .pause: return "paused"
        case .stop: return "stopped"
        case .toggle: return "toggled"
        case .next: return "skipped"
        case .previous: return "went back"
        case .volume: return "volume set"
        }
    }
}

public struct PlayerSnapshot: Equatable, Sendable {
    public var player: MusicPlayer
    public var isRunning: Bool
    public var isPlaying: Bool
    public var title: String
    public var artist: String
    public var elapsedSeconds: Double
    public var durationSeconds: Double
    public var volume: Double?

    public init(
        player: MusicPlayer, isRunning: Bool = false, isPlaying: Bool = false,
        title: String = "", artist: String = "", elapsedSeconds: Double = 0,
        durationSeconds: Double = 0, volume: Double? = nil
    ) {
        self.player = player
        self.isRunning = isRunning
        self.isPlaying = isPlaying
        self.title = title
        self.artist = artist
        self.elapsedSeconds = elapsedSeconds
        self.durationSeconds = durationSeconds
        self.volume = volume
    }

    public var hasTrack: Bool { !title.isEmpty }

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

public enum MusicTargeting {
    public static let priority: [MusicPlayer] = [.builtin, .spotify, .apple]

    public static func rank(_ snapshot: PlayerSnapshot) -> Int {
        guard snapshot.isRunning else { return 0 }
        var score = 1
        if snapshot.hasTrack { score += 2 }
        if snapshot.isPlaying { score += 4 }
        return score
    }

    public static func resolve(
        _ snapshots: [PlayerSnapshot], forced: MusicPlayer? = nil, preferred: MusicPlayer? = nil
    ) throws -> PlayerSnapshot {
        if let forced {
            guard let found = snapshots.first(where: { $0.player == forced }) else {
                throw CLIFailure.notFound("no player named \(forced.rawValue)")
            }
            guard found.isRunning else {
                throw CLIFailure.unavailable(
                    "\(forced.displayName) is not running",
                    hint: forced == .builtin
                        ? "open Edith and turn the Music extension on"
                        : "open \(forced.displayName), then retry")
            }
            return found
        }
        let ordered =
            priority.compactMap { player in snapshots.first { $0.player == player } }
        var best: PlayerSnapshot?
        for snapshot in ordered {
            guard let current = best else {
                best = snapshot
                continue
            }
            if rank(snapshot) > rank(current) { best = snapshot }
            if rank(snapshot) == rank(current), snapshot.player == preferred,
                current.player != preferred
            {
                best = snapshot
            }
        }
        guard let best, rank(best) > 0 else {
            throw CLIFailure.unavailable(
                "no music player is running",
                hint: "open Spotify or Apple Music, or turn on Edith's Music extension")
        }
        return best
    }
}
