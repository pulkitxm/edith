import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

enum MusicSceneRoute: String, CaseIterable {
    case page = "main"
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

@MainActor enum MusicAuxiliaryScenes {
    static func controller(_ input: NSDictionary) -> NSViewController? {
        guard let route = MusicSceneRoute(input) else { return nil }
        switch route {
        case .page:
            return NSHostingController(rootView: ExtensionPageHost { MusicPage() })
        case .footer:
            return NSHostingController(rootView: ExtensionPageHost { MusicFooterScene() })
        case .sidebar:
            return NSHostingController(rootView: ExtensionPageHost { MusicSidebarScene() })
        case .detail:
            return NSHostingController(rootView: ExtensionPageHost { MusicDetailOverlay() })
        }
    }
}

struct MusicFooterScene: View {
    @State private var accounts = MusicAccounts.shared
    @AppStorage(AppStorageKeys.Music.barAutoHide, store: SharedDefaults.store) private
        var autoHide = false

    var body: some View {
        if accounts.playerReady && (!autoHide || accounts.playerTitle != nil) { MusicFooter() }
    }
}

struct MusicSidebarScene: View {
    @State private var accounts = MusicAccounts.shared
    @AppStorage(AppStorageKeys.Music.barAutoHide, store: SharedDefaults.store) private
        var autoHide = false
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var theme =
        "accent"
    @AppStorage(AppStorageKeys.Music.barCollapsed, store: SharedDefaults.store) private
        var collapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if accounts.playerReady && (!autoHide || accounts.playerTitle != nil) {
            MusicSidebarPill(theme: themeColor(theme)) {
                withAnimation(Motion.animation(Motion.glide, reduceMotion: reduceMotion)) {
                    collapsed = false
                }
            }
        }
    }
}
