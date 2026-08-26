import EdithKit
import Foundation

enum NotchTab: String, CaseIterable, Equatable {
    case home, files, clipboard, audio, camera

    static func visible(
        clipboardEnabled: Bool, audioMixerEnabled: Bool, applicationAudioSupported: Bool
    ) -> [NotchTab] {
        var tabs: [NotchTab] = [.home, .files]
        if clipboardEnabled { tabs.append(.clipboard) }
        if audioMixerEnabled, applicationAudioSupported { tabs.append(.audio) }
        tabs.append(.camera)
        return tabs
    }

    static var currentVisible: [NotchTab] {
        visible(
            clipboardEnabled: SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.enabled),
            audioMixerEnabled: SharedDefaults.store.bool(
                forKey: AppStorageKeys.Notch.audioMixerEnabled),
            applicationAudioSupported: PlatformCapabilities.macOS.state(for: .applicationAudio)
                .isSupported)
    }

    static func validSelection(_ selected: NotchTab, visible: [NotchTab]) -> NotchTab {
        visible.contains(selected) ? selected : .home
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
