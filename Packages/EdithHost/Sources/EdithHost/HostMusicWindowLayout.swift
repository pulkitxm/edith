import SwiftUI

enum HostMusicRegion: String {
    case footer = "music.footer"
    case sidebar = "music.sidebar"

    var initialHeight: Double {
        switch self {
        case .footer: 64
        case .sidebar: 40
        }
    }
}

struct HostMusicWindowLayout<Main: View, Footer: View>: View {
    let main: Main
    let footer: Footer

    init(@ViewBuilder main: () -> Main, @ViewBuilder footer: () -> Footer) {
        self.main = main(); self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            main.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer.frame(maxWidth: .infinity)
        }
        .ignoresSafeArea()
    }
}
