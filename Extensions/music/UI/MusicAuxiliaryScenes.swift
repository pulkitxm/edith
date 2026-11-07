import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

enum EmbeddedMusicSceneRoute: String, CaseIterable {
    case page = "main"
    case settings = "settings"
    case footer = "music.footer"
    case sidebar = "music.sidebar"
    case detail = "music.detail"

    init?(_ input: NSDictionary) {
        guard input["section"] as? String == "music",
            let location = input["location"] as? String,
            let route = Self(rawValue: location)
        else { return nil }
        self = route
    }
}

@MainActor enum EmbeddedMusicAuxiliaryScenes {
    static func controller(_ input: NSDictionary) -> NSViewController? {
        guard let route = EmbeddedMusicSceneRoute(input) else { return nil }
        switch route {
        case .page:
            return NSHostingController(rootView: ExtensionPageHost { EmbeddedMusicEmbeddedPage() })
        case .settings:
            return NSHostingController(
                rootView: ExtensionPageHost {
                    EmbeddedMusicSceneLoad { EmbeddedMusicSettingsScene() }
                })
        case .footer:
            return NSHostingController(
                rootView: ExtensionPageHost {
                    EmbeddedMusicSceneLoad { EmbeddedMusicFooterScene().musicWindowDetail() }
                })
        case .sidebar:
            return NSHostingController(
                rootView: ExtensionPageHost {
                    EmbeddedMusicSceneLoad { EmbeddedMusicSidebarScene().musicWindowDetail() }
                })
        case .detail:
            return NSHostingController(
                rootView: ExtensionPageHost {
                    EmbeddedMusicSceneLoad { EmbeddedMusicDetailOverlay() }
                })
        }
    }
}

struct EmbeddedMusicFooterScene: View {
    var remote = EmbeddedMusicRemote.shared
    var privacy = EmbeddedMusicPrivacyState.shared
    @State private var accounts = EmbeddedMusicAccounts.shared
    @AppStorage(AppStorageKeys.Music.barAutoHide, store: SharedDefaults.store) private
        var autoHide = false

    var body: some View {
        if accounts.playerReady && (!autoHide || accounts.playerTitle != nil) {
            EmbeddedMusicFooter(remote: remote).musicPresenterCover(privacy)
        }
    }
}

struct EmbeddedMusicSidebarScene: View {
    var remote = EmbeddedMusicRemote.shared
    var privacy = EmbeddedMusicPrivacyState.shared
    @State private var accounts = EmbeddedMusicAccounts.shared
    @AppStorage(AppStorageKeys.Music.barAutoHide, store: SharedDefaults.store) private
        var autoHide = false
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var theme =
        AppTheme.standard.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if accounts.playerReady && (!autoHide || accounts.playerTitle != nil) {
            EmbeddedMusicSidebarPill(theme: themeColor(theme)) {
                withAnimation(Motion.animation(Motion.glide, reduceMotion: reduceMotion)) {
                    remote.setBarCollapsed(false)
                }
            }
            .musicPresenterCover(privacy)
        }
    }
}

private struct MusicPresenterCover: ViewModifier {
    var privacy: EmbeddedMusicPrivacyState
    @Environment(\.colorScheme) private var scheme

    private var presenting: Bool { privacy.hides(.music) }

    func body(content: Content) -> some View {
        content.disabled(presenting).presenterCover(presenting, dark: scheme == .dark)
    }
}

extension View {
    func musicPresenterCover(_ privacy: EmbeddedMusicPrivacyState) -> some View {
        modifier(MusicPresenterCover(privacy: privacy))
    }
}

struct EmbeddedMusicSettingsScene: View {
    var body: some View { EmbeddedMusicSettings { EmbeddedMusicRemote.shared.send(.openMusic) } }
}
