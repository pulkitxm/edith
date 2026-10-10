import EdithExtensionSupport
import EdithExtensionCommands
import Foundation

@MainActor public enum MusicMemory {
    public static let key = "cliActivePlayer"

    public static var last: MusicPlayer? {
        MusicCLIEnvironment.sharedDefaults.string(forKey: key).flatMap(MusicPlayer.init(rawValue:))
    }

    public static func remember(_ player: MusicPlayer) {
        MusicCLIEnvironment.sharedDefaults.set(player.rawValue, forKey: key)
        MusicCLIEnvironment.sharedDefaults.synchronize()
    }
}

@MainActor public enum MusicSession {
    public static func builtinSnapshot(timeout: TimeInterval = 2) async -> PlayerSnapshot {
        await MusicCLIEnvironment.readBuiltin()
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
        let resolved: PlayerSnapshot
        do {
            resolved = try MusicTargeting.resolve(
                observed, forced: forced, preferred: MusicMemory.last)
        } catch let error as MusicTransportError {
            throw error.cliFailure
        }
        return (resolved, all)
    }

    static func missing(from observed: [PlayerSnapshot]) -> [PlayerSnapshot] {
        MusicPlayer.allCases
            .filter { player in !observed.contains { $0.player == player } }
            .map { PlayerSnapshot(player: $0) }
    }

    public static func send(_ action: PlayerAction, to player: MusicPlayer) async throws {
        if player == .builtin {
            try MusicCLIEnvironment.requirePlayer()
            MusicCLIEnvironment.sendBuiltin(.action(action))
        } else {
            try ExternalPlayers.send(action, to: player)
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
