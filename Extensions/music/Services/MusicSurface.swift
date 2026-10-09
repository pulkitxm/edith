import CryptoKit
import EdithExtensionSupport
import Foundation

struct MusicSurfaceTrack: Equatable, Sendable {
    var key: String
    var title: String
}

struct MusicSurfacePlayback: Equatable, Sendable {
    var sourceID: String
    var sourceTitle: String
    var trackKey: String
    var title: String
    var artist = ""
    var playing = false
    var elapsed = 0.0
    var duration = 0.0
    var volume = 0.7
    var shuffle: Bool?
    var repeating: Bool?
    var thumbnail: SurfaceThumbnail?
    var queue: [MusicSurfaceTrack] = []

    var token: String { Self.token(sourceID + "\0" + trackKey) }
    static func token(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    func identifier(_ action: String) -> String { action + ":" + sourceID + ":" + token }
    func queuedIdentifier(_ track: MusicSurfaceTrack) -> String {
        "playQueue:" + sourceID + ":" + Self.token(sourceID + "\0" + track.key)
    }
}

struct MusicSurfaceCommand: Equatable, Sendable {
    var sourceID: String
    var trackKey: String
    var action: String
    var value: Double?
}

@MainActor
final class MusicSurface {
    typealias Read = @MainActor (SurfaceTile) async throws -> [MusicSurfacePlayback]
    typealias Perform = @MainActor (MusicSurfaceCommand) async throws -> Void
    private let read: Read
    private let perform: Perform
    private let privacyValues: @MainActor () -> [String: String]

    init(
        read: @escaping Read, perform: @escaping Perform,
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) {
        self.read = read; self.perform = perform; self.privacyValues = privacyValues
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        let request: SurfaceSnapshotRequest
        if command == "surface.perform" {
            request = try SurfaceActionRequest.decode(payload, providerID: "music").snapshot
        } else {
            request = try SurfaceSnapshotRequest.decode(payload, providerID: "music")
        }
        return try await SurfaceCommandService.execute(
            providerID: "music", command: command, payload: payload,
            snapshot: { [self] tile in
                Self.snapshot(try await read(tile), tile: tile, target: request.target)
            },
            perform: { [self] identifier in
                try await dispatch(identifier, value: nil, tile: request.tile)
            },
            adjust: { [self] identifier, value in
                try await dispatch(identifier, value: value, tile: request.tile)
            },
            privacyValues: privacyValues)
    }

    private func dispatch(_ identifier: String, value: Double?, tile: SurfaceTile) async throws {
        let states = try await read(tile)
        try Task.checkCancellation()
        for state in states {
            let commands = [
                "open", "toggle", "previous", "next", "shuffle", "repeat", "backward", "forward",
                "seek", "volume",
            ]
            if let action = commands.first(where: { state.identifier($0) == identifier }) {
                try await perform(
                    .init(
                        sourceID: state.sourceID, trackKey: state.trackKey, action: action,
                        value: value))
                return
            }
            if let track = state.queue.first(where: { state.queuedIdentifier($0) == identifier }) {
                try await perform(
                    .init(
                        sourceID: state.sourceID, trackKey: track.key, action: "playQueue",
                        value: nil))
                return
            }
        }
        throw ExtensionPeerError.invalidRequest
    }

    static func snapshot(_ states: [MusicSurfacePlayback], tile: SurfaceTile, target: SurfaceTarget)
        -> SurfaceSnapshot
    {
        let selected = states.filter { tile.sourceIDs?.contains($0.sourceID) ?? true }
        let ordered = selected.sorted { $0.playing && !$1.playing }
        var rows: [SurfaceDataRow] = []
        for state in ordered {
            let playing = !state.trackKey.isEmpty
            var actions = [
                SurfaceAction(state.identifier("open"), "Open Music", "arrow.up.forward.app")
            ]
            if playing {
                actions += [
                    .init(state.identifier("previous"), "Previous", "backward.end.fill"),
                    .init(
                        state.identifier("toggle"), state.playing ? "Pause" : "Play",
                        state.playing ? "pause.fill" : "play.fill"),
                    .init(state.identifier("next"), "Next", "forward.end.fill"),
                ]
                if target == .notch {
                    actions += [
                        .init(
                            state.identifier("backward"), "Back 15 seconds", "gobackward.15",
                            field: "seekControls"),
                        .init(
                            state.identifier("forward"), "Forward 15 seconds", "goforward.15",
                            field: "seekControls"),
                    ]
                    if let shuffle = state.shuffle {
                        actions.append(
                            .init(
                                state.identifier("shuffle"), shuffle ? "Shuffle on" : "Shuffle off",
                                "shuffle", field: "shuffle"))
                    }
                    if let repeating = state.repeating {
                        actions.append(
                            .init(
                                state.identifier("repeat"), repeating ? "Repeat on" : "Repeat off",
                                "repeat", field: "repeat"))
                    }
                }
            }
            var sliders: [SurfaceSlider] = []
            if playing, target == .notch {
                if state.duration > 0 {
                    sliders.append(
                        .init(
                            state.identifier("seek"), "Playback position", "clock",
                            value: UnitInterval.clamp(state.elapsed / state.duration),
                            field: "progress"))
                }
                sliders.append(
                    .init(
                        state.identifier("volume"), "Volume", "speaker.wave.2.fill",
                        value: UnitInterval.clamp(state.volume), field: "volume"))
            }
            rows.append(
                .init(
                    state.sourceID + ":" + state.token, sourceID: state.sourceID,
                    title: text(playing ? state.title : "Nothing playing"),
                    detail: tile.shows("artist") ? text(state.artist, empty: true) : "",
                    value: playing
                        ? (state.playing ? "Playing" : "Paused")
                            + (tile.shows("progress")
                                ? " · " + time(state.elapsed) + " / " + time(state.duration) : "")
                        : state.sourceTitle,
                    icon: "music.note",
                    progress: playing && state.duration > 0
                        ? UnitInterval.clamp(state.elapsed / state.duration) : nil,
                    actions: actions, sliders: sliders,
                    thumbnail: tile.shows("artwork") ? state.thumbnail : nil))
            if tile.shows("queue") {
                rows += state.queue.prefix(10).map { track in
                    .init(
                        "queue:" + MusicSurfacePlayback.token(state.sourceID + "\0" + track.key),
                        sourceID: state.sourceID,
                        title: text(track.title), detail: "Up next", icon: "music.note.list",
                        field: "queue",
                        actions: [
                            .init(
                                state.queuedIdentifier(track), "Play", "play.fill", field: "queue")
                        ])
                }
            }
        }
        return .init(
            providerID: "music", rows: rows,
            sources: states.map { .init($0.sourceID, $0.sourceTitle) },
            message: rows.isEmpty ? "No available player in this selection." : nil, updatedAt: .now)
    }

    private static func text(_ value: String, empty: Bool = false) -> String {
        let text = String(value.replacingOccurrences(of: "\0", with: "").prefix(256))
        return text.isEmpty && !empty ? "Untitled track" : text
    }
    private static func time(_ value: Double) -> String {
        let seconds = value.isFinite ? max(0, min(value, 86_400)) : 0
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
