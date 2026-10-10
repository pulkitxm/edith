import EdithExtensionSupport
import Foundation

struct EmbeddedMusicNotchPlayback: Codable, Equatable {
    var rowID: String
    var sourceName: String
    var playing: Bool
    var elapsed: Double
    var duration: Double
    var shuffle: Bool?
    var repeating: Bool?
    var appIcon: SurfaceThumbnail?
}

struct EmbeddedMusicNotchState: Codable, Equatable {
    var snapshot: SurfaceSnapshot
    var playback: [EmbeddedMusicNotchPlayback]

    func encoded() throws -> Data {
        _ = try snapshot.encoded()
        guard snapshot.providerID == "music", playback.count <= 100,
            Set(playback.map(\.rowID)).count == playback.count,
            playback.allSatisfy({ value in
                snapshot.rows.contains { $0.id == value.rowID }
                    && !value.sourceName.isEmpty && value.sourceName.utf8.count <= 256
                    && !value.sourceName.contains("\0")
                    && value.elapsed.isFinite && value.duration.isFinite
                    && value.elapsed >= 0 && value.duration >= 0
                    && value.elapsed <= 86_400 && value.duration <= 86_400
            })
        else { throw ExtensionPeerError.invalidRequest }
        for value in playback { try value.appIcon?.validate() }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        let state = try JSONDecoder().decode(Self.self, from: data)
        _ = try state.encoded()
        return state
    }
}
