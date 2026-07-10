import Foundation

struct NotchNowPlaying: Equatable {
    enum Source: Equatable {
        case local
        case external(ExternalApp)
    }

    var source: Source
    var title: String
    var artist: String
    var isPlaying: Bool
}

enum NotchMusicResolver {
    static func resolve(
        localTitle: String?, localPlaying: Bool, external: ExternalTrack?
    ) -> NotchNowPlaying? {
        if let localTitle, !localTitle.isEmpty {
            return NotchNowPlaying(
                source: .local, title: localTitle, artist: "", isPlaying: localPlaying)
        }
        if let external {
            return NotchNowPlaying(
                source: .external(external.app), title: external.title, artist: external.artist,
                isPlaying: external.isPlaying)
        }
        return nil
    }
}
