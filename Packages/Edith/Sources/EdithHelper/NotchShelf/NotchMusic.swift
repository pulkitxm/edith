import EdithKit
import Foundation

enum NotchTab: String, CaseIterable, Equatable {
    case home, files, clipboard, audio, camera

    static var allCases: [NotchTab] {
        var tabs: [NotchTab] = [.home, .files]
        if SharedDefaults.store.bool(forKey: "clipboardEnabled") { tabs.append(.clipboard) }
        tabs.append(contentsOf: [.audio, .camera])
        return tabs
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .files: "Files"
        case .clipboard: "Clipboard"
        case .audio: "Audio"
        case .camera: "Camera"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .files: "folder.fill"
        case .clipboard: "doc.on.clipboard"
        case .audio: "slider.horizontal.3"
        case .camera: "camera.fill"
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
        case .external:
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
        case .none:
            return nil
        }
    }
}
