import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct MusicRootView: View {
    enum Section: String, CaseIterable {
        case library = "Music", downloads = "Downloads", settings = "Settings"
    }
    @Environment(\.colorScheme) private var scheme
    @State private var section = Section.library
    private let accounts: MusicAccounts
    private let downloader: YoutubeDownloader

    init(
        initialSection: Section = .library, accounts: MusicAccounts? = nil,
        downloader: YoutubeDownloader? = nil
    ) {
        _section = State(initialValue: initialSection)
        self.accounts = accounts ?? .shared
        self.downloader = downloader ?? .shared
    }

    var body: some View {
        VStack(spacing: 0) {
            EdithSegmentedPicker(
                "Music", selection: $section, options: Section.allCases, label: \.rawValue
            )
            .frame(maxWidth: UIScale.pt(440))
            .padding(UIScale.pt(12))
            switch section {
            case .library: MusicPage(accounts: accounts)
            case .downloads: DownloadSheet(isPage: true, downloader: downloader)
            case .settings: MusicSettings { section = .library }
            }
            MusicFooter(accounts: accounts)
        }
        .background(DashSkin.paper(scheme == .dark))
        .overlay { MusicDetailOverlay() }
    }
}
