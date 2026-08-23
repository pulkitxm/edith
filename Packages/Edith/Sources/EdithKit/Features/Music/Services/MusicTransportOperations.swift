import EdithCore
import Foundation

public enum MusicTransportOperation: String, CaseIterable, Sendable {
    case play
    case pause
    case stop
    case toggle
    case next
    case previous
    case start
    case seek
    case volume
    case shuffle
    case `repeat`
    case status

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "music.transport.\(rawValue)"), summary: summary,
            cli: ["music", rawValue], effect: self == .status ? .read : .write)
    }

    private var summary: String {
        switch self {
        case .play: "Resume playback on the active player."
        case .pause: "Pause the active player."
        case .stop: "Stop playback and reset its position."
        case .toggle: "Toggle play and pause."
        case .next: "Skip to the next track."
        case .previous: "Go back to the previous track."
        case .start: "Start a library track or folder."
        case .seek: "Seek within the current library track."
        case .volume: "Set the active player's volume."
        case .shuffle: "Set library shuffle state."
        case .repeat: "Set library repeat state."
        case .status: "Show the active player and playback state."
        }
    }
}

public enum MusicCurrentOperation: String, CaseIterable, Sendable {
    case openCurrent = "open-current"
    case revealCurrent = "reveal-current"

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "music.current.\(rawValue)"), summary: summary,
            cli: ["music", rawValue], effect: .interactive)
    }

    private var summary: String {
        switch self {
        case .openCurrent: "Open the player for the current track."
        case .revealCurrent: "Reveal the current library track or open its player."
        }
    }
}

public enum MusicPlayer: String, CaseIterable, Sendable {
    case builtin
    case spotify
    case apple

    public var displayName: String {
        switch self {
        case .builtin: "Edith"
        case .spotify: "Spotify"
        case .apple: "Apple Music"
        }
    }

    public var processName: String? {
        switch self {
        case .builtin: nil
        case .spotify: "Spotify"
        case .apple: "Music"
        }
    }

    public var bundleIdentifier: String? {
        switch self {
        case .builtin: nil
        case .spotify: "com.spotify.client"
        case .apple: "com.apple.Music"
        }
    }

    public var isExternal: Bool { processName != nil }

    public static let spellings: [String: MusicPlayer] = [
        "builtin": .builtin, "built-in": .builtin, "edith": .builtin, "internal": .builtin,
        "spotify": .spotify,
        "apple": .apple, "applemusic": .apple, "apple-music": .apple, "music": .apple,
        "itunes": .apple,
    ]

    public static func resolveName(_ text: String) -> MusicPlayer? {
        spellings[text.lowercased()]
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
    public var trackPath: String?

    public init(
        player: MusicPlayer, isRunning: Bool = false, isPlaying: Bool = false,
        title: String = "", artist: String = "", elapsedSeconds: Double = 0,
        durationSeconds: Double = 0, volume: Double? = nil, trackPath: String? = nil
    ) {
        self.player = player
        self.isRunning = isRunning
        self.isPlaying = isPlaying
        self.title = title
        self.artist = artist
        self.elapsedSeconds = elapsedSeconds
        self.durationSeconds = durationSeconds
        self.volume = volume
        self.trackPath = trackPath
    }

    public var hasTrack: Bool { !title.isEmpty }
}

public struct MusicCurrentTarget: Equatable, Sendable {
    public var player: MusicPlayer
    public var trackPath: String?

    public init(player: MusicPlayer, trackPath: String? = nil) {
        self.player = player
        self.trackPath = trackPath
    }
}

public struct MusicCurrentOperationResult: Equatable, Sendable {
    public var operation: MusicCurrentOperation
    public var player: MusicPlayer
    public var trackPath: String?
    public var revealed: Bool

    public init(
        operation: MusicCurrentOperation, player: MusicPlayer, trackPath: String?, revealed: Bool
    ) {
        self.operation = operation
        self.player = player
        self.trackPath = trackPath
        self.revealed = revealed
    }
}

public enum MusicCurrentOperationError: LocalizedError, Equatable {
    case openFailed(MusicPlayer)
    case revealFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let player): "Could not open \(player.displayName)."
        case .revealFailed(let path): "Could not reveal \(path)."
        }
    }
}

public enum MusicCurrentOperationExecution {
    @discardableResult
    public static func perform(
        _ operation: MusicCurrentOperation, target: MusicCurrentTarget,
        openPlayer: (MusicPlayer) -> Bool, revealTrack: (String) -> Bool
    ) throws -> MusicCurrentOperationResult {
        if operation == .revealCurrent, target.player == .builtin,
            let trackPath = target.trackPath, !trackPath.isEmpty
        {
            guard revealTrack(trackPath) else {
                throw MusicCurrentOperationError.revealFailed(trackPath)
            }
            return MusicCurrentOperationResult(
                operation: operation, player: target.player, trackPath: trackPath, revealed: true)
        }
        guard openPlayer(target.player) else {
            throw MusicCurrentOperationError.openFailed(target.player)
        }
        return MusicCurrentOperationResult(
            operation: operation, player: target.player, trackPath: target.trackPath,
            revealed: false)
    }
}

public enum MusicTransportError: LocalizedError, Equatable {
    case playerNotRunning(MusicPlayer)
    case noPlayer

    public var errorDescription: String? {
        switch self {
        case .playerNotRunning(let player): "\(player.displayName) is not running."
        case .noPlayer: "No music player is running."
        }
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
        _ snapshots: [PlayerSnapshot], forced: MusicPlayer? = nil,
        preferred: MusicPlayer? = nil
    ) throws -> PlayerSnapshot {
        if let forced {
            guard let found = snapshots.first(where: { $0.player == forced }), found.isRunning
            else { throw MusicTransportError.playerNotRunning(forced) }
            return found
        }
        let ordered = priority.compactMap { player in snapshots.first { $0.player == player } }
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
        guard let best, rank(best) > 0 else { throw MusicTransportError.noPlayer }
        return best
    }
}

public enum MusicTransportRequest: Equatable, Sendable {
    case play
    case pause
    case stop
    case toggle
    case next
    case previous
    case startTrack(String)
    case startSource(MusicSourceRequest, start: String? = nil)
    case seek(Double)
    case volume(Double)
    case shuffle(Bool)
    case `repeat`(Bool)
    case status

    public static func action(_ action: PlayerAction) -> MusicTransportRequest {
        switch action {
        case .play: .play
        case .pause: .pause
        case .stop: .stop
        case .toggle: .toggle
        case .next: .next
        case .previous: .previous
        case .volume(let value): .volume(value)
        }
    }
}

public struct BuiltinCommand: Equatable, Sendable {
    public let action: String
    public let value: Double?

    public init(_ action: String, value: Double? = nil) {
        self.action = action
        self.value = value
    }

    public var userInfo: [String: Any] {
        guard let value else { return ["action": action] }
        return ["action": action, "value": value]
    }
}

public enum MusicTransportExecution {
    public static func fraction(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    public static func builtinCommands(_ action: PlayerAction) -> [BuiltinCommand] {
        switch action {
        case .play: [BuiltinCommand("resume")]
        case .pause: [BuiltinCommand("pause")]
        case .stop: [BuiltinCommand("pause"), BuiltinCommand("seek", value: 0)]
        case .toggle: [BuiltinCommand("playPause")]
        case .next: [BuiltinCommand("next")]
        case .previous: [BuiltinCommand("previous")]
        case .volume(let value): [BuiltinCommand("volume", value: fraction(value))]
        }
    }

    public static func payloads(for request: MusicTransportRequest) -> [[String: Any]] {
        switch request {
        case .play: return [BuiltinCommand("resume").userInfo]
        case .pause: return [BuiltinCommand("pause").userInfo]
        case .stop:
            return [BuiltinCommand("pause").userInfo, BuiltinCommand("seek", value: 0).userInfo]
        case .toggle: return [BuiltinCommand("playPause").userInfo]
        case .next: return [BuiltinCommand("next").userInfo]
        case .previous: return [BuiltinCommand("previous").userInfo]
        case .startTrack(let path): return [["action": "toggle", "track": path]]
        case .startSource(let source, let start):
            var payload = source.payload
            payload["action"] = "playSource"
            if let start { payload["start"] = start }
            return [payload]
        case .seek(let value): return [BuiltinCommand("seek", value: fraction(value)).userInfo]
        case .volume(let value):
            return [BuiltinCommand("volume", value: fraction(value)).userInfo]
        case .shuffle(let enabled): return [["action": "shuffle", "value": enabled]]
        case .repeat(let enabled): return [["action": "loop", "value": enabled]]
        case .status: return []
        }
    }

    public static func perform(
        _ request: MusicTransportRequest, sendCommand: ([String: Any]) -> Void,
        requestStatus: () -> Void = {}
    ) {
        guard request != .status else {
            requestStatus()
            return
        }
        for payload in payloads(for: request) { sendCommand(payload) }
    }

    public static func perform(
        _ action: PlayerAction, on player: MusicPlayer,
        sendBuiltin: (BuiltinCommand) -> Void,
        sendExternal: (PlayerAction, MusicPlayer) throws -> Void
    ) throws {
        if player == .builtin {
            for command in builtinCommands(action) { sendBuiltin(command) }
        } else {
            try sendExternal(action, player)
        }
    }
}
