import SwiftUI

enum HostMusicRegion: String {
    case footer = "music.footer"
    case sidebar = "music.sidebar"
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
