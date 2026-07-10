import Foundation

enum NotchTab: String, CaseIterable, Equatable {
    case home, files, clipboard

    var title: String {
        switch self {
        case .home: "Home"
        case .files: "Files"
        case .clipboard: "Clipboard"
        }
    }
}

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
        let hasLocal = localTitle?.isEmpty == false
        if hasLocal, localPlaying {
            return NotchNowPlaying(source: .local, title: localTitle!, artist: "", isPlaying: true)
        }
        if let external, external.isPlaying {
            return NotchNowPlaying(
                source: .external(external.app), title: external.title, artist: external.artist,
                isPlaying: true)
        }
        if hasLocal {
            return NotchNowPlaying(source: .local, title: localTitle!, artist: "", isPlaying: false)
        }
        if let external {
            return NotchNowPlaying(
                source: .external(external.app), title: external.title, artist: external.artist,
                isPlaying: external.isPlaying)
        }
        return nil
    }
}
