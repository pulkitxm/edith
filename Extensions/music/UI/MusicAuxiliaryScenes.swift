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
                    EmbeddedMusicSceneLoad { EmbeddedMusicFooterScene() }
                })
        case .sidebar:
            return NSHostingController(
                rootView: ExtensionPageHost {
                    EmbeddedMusicSceneLoad { EmbeddedMusicSidebarScene() }
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
    @State private var accounts = EmbeddedMusicAccounts.shared
    @AppStorage(AppStorageKeys.Music.barAutoHide, store: SharedDefaults.store) private
        var autoHide = false

    var body: some View {
        if accounts.playerReady && (!autoHide || accounts.playerTitle != nil) {
            EmbeddedMusicFooter()
        }
    }
}

struct EmbeddedMusicSidebarScene: View {
    @State private var accounts = EmbeddedMusicAccounts.shared
    @AppStorage(AppStorageKeys.Music.barAutoHide, store: SharedDefaults.store) private
        var autoHide = false
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var theme =
        "accent"
    @AppStorage(AppStorageKeys.Music.barCollapsed, store: SharedDefaults.store) private
        var collapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if accounts.playerReady && (!autoHide || accounts.playerTitle != nil) {
            EmbeddedMusicSidebarPill(theme: themeColor(theme)) {
                withAnimation(Motion.animation(Motion.glide, reduceMotion: reduceMotion)) {
                    collapsed = false; EmbeddedMusicRemote.shared.send(.barCollapsed, value: 0)
                }
            }
        }
    }
}

struct EmbeddedMusicSettingsScene: View {
    @AppStorage(AppStorageKeys.General.mainWindowSection, store: SharedDefaults.store) private
        var section = "home"

    var body: some View { EmbeddedMusicSettings { EmbeddedMusicRemote.shared.send(.openMusic) } }
}
