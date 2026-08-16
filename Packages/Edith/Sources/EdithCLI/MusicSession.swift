import EdithKit
import Foundation

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

public enum MusicMemory {
    public static let key = "cliActivePlayer"

    public static var last: MusicPlayer? {
        CLIEnvironment.sharedDefaults.string(forKey: key).flatMap(MusicPlayer.init(rawValue:))
    }

    public static func remember(_ player: MusicPlayer) {
        CLIEnvironment.sharedDefaults.set(player.rawValue, forKey: key)
        CLIEnvironment.sharedDefaults.synchronize()
    }
}

public enum MusicSession {
    public static let builtinExtensionKey = AppStorageKeys.Tabs.musicEnabled

    public static func builtinCommands(_ action: PlayerAction) -> [BuiltinCommand] {
        switch action {
        case .play: return [BuiltinCommand("resume")]
        case .pause: return [BuiltinCommand("pause")]
        case .stop: return [BuiltinCommand("pause"), BuiltinCommand("seek", value: 0)]
        case .toggle: return [BuiltinCommand("playPause")]
        case .next: return [BuiltinCommand("next")]
        case .previous: return [BuiltinCommand("previous")]
        case let .volume(level): return [BuiltinCommand("volume", value: level)]
        }
    }

    public static func decodeBuiltin(_ payload: [AnyHashable: Any]) -> PlayerSnapshot {
        let track = payload["track"] as? String ?? ""
        return PlayerSnapshot(
            player: .builtin, isRunning: true,
            isPlaying: payload["isPlaying"] as? Bool ?? false,
            title: track.isEmpty ? "" : (track as NSString).lastPathComponent,
            elapsedSeconds: payload["elapsed"] as? Double ?? 0,
            durationSeconds: payload["duration"] as? Double ?? 0,
            volume: payload["volume"] as? Double)
    }

    public static var builtinIsReachable: Bool {
        AppBridge.helperIsRunning
            && CLIEnvironment.sharedDefaults.object(forKey: builtinExtensionKey) as? Bool ?? false
    }

    public static func builtinSnapshot(timeout: TimeInterval = 2) async -> PlayerSnapshot {
        guard builtinIsReachable else { return PlayerSnapshot(player: .builtin) }
        guard
            let payload = await AppBridge.awaitReply(
                IPC.Name.musicState, timeout: timeout,
                trigger: { AppBridge.post(IPC.Name.requestMusicState) })
        else { return PlayerSnapshot(player: .builtin) }
        return decodeBuiltin(payload)
    }

    public static func snapshots(_ players: [MusicPlayer] = MusicPlayer.allCases) async
        -> [PlayerSnapshot]
    {
        var out: [PlayerSnapshot] = []
        for player in players {
            if player == .builtin {
                out.append(await builtinSnapshot())
            } else {
                out.append(ExternalPlayers.snapshot(player))
            }
        }
        return out
    }

    public static func target(forced: MusicPlayer?) async throws -> (
        snapshot: PlayerSnapshot, all: [PlayerSnapshot]
    ) {
        let players = forced.map { [$0] } ?? MusicPlayer.allCases
        let observed = await snapshots(players)
        let all = forced == nil ? observed : observed + missing(from: observed)
        let resolved = try MusicTargeting.resolve(
            observed, forced: forced, preferred: MusicMemory.last)
        return (resolved, all)
    }

    static func missing(from observed: [PlayerSnapshot]) -> [PlayerSnapshot] {
        MusicPlayer.allCases
            .filter { player in !observed.contains { $0.player == player } }
            .map { PlayerSnapshot(player: $0) }
    }

    public static func send(_ action: PlayerAction, to player: MusicPlayer) async throws {
        guard player == .builtin else {
            try ExternalPlayers.send(action, to: player)
            return
        }
        guard builtinIsReachable else {
            throw AppBridge.silence("Edith's own player", extensionKey: builtinExtensionKey)
        }
        for command in builtinCommands(action) {
            AppBridge.post(IPC.Name.musicCommand, userInfo: command.userInfo)
        }
    }

    public static func report(active: PlayerSnapshot?, all: [PlayerSnapshot]) -> JSONValue {
        .object([
            "active": active.map(\.json) ?? .null,
            "player": active.map { .string($0.player.rawValue) } ?? JSONValue.null,
            "players": .array(
                MusicPlayer.allCases.compactMap { player in
                    all.first { $0.player == player }?.json
                }),
        ])
    }
}
