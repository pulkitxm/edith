import EdithExtensionUI
import SwiftUI

struct MusicRootView: View {
    enum Section: String, CaseIterable {
        case library = "Music", downloads = "Downloads", settings = "Settings"
    }
    @State private var section = Section.library

    var body: some View {
        VStack(spacing: 0) {
            EdithSegmentedPicker(
                "Music", selection: $section, options: Section.allCases, label: \.rawValue
            )
            .frame(maxWidth: UIScale.pt(440))
            .padding(UIScale.pt(12))
            switch section {
            case .library: MusicPage()
            case .downloads: DownloadSheet(isPage: true)
            case .settings: MusicSettings { section = .library }
            }
            MusicFooter()
        }
        .overlay { MusicDetailOverlay() }
    }
}
