import EdithKit
import Foundation

typealias NotchTab = SurfaceNotchTab

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
        localTitle: String?, localPlaying: Bool, external: ExternalTrack?,
        previous: NotchNowPlaying? = nil
    ) -> NotchNowPlaying? {
        let hasLocal = localTitle?.isEmpty == false
        if hasLocal, localPlaying {
            return NotchNowPlaying(source: .local, title: localTitle!, artist: "", isPlaying: true)
        }
        if let external, external.isPlaying {
            return NotchNowPlaying(
                source: .external(external.app), title: external.title, artist: external.artist,
                isPlaying: true)
        }
        switch previous?.source {
        case .external, .none:
            return external.map {
                NotchNowPlaying(
                    source: .external($0.app), title: $0.title, artist: $0.artist,
                    isPlaying: $0.isPlaying)
            }
        case .local:
            return hasLocal
                ? NotchNowPlaying(
                    source: .local, title: localTitle!, artist: "", isPlaying: false)
                : nil
        }
    }
}
