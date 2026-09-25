import EdithKit
import EdithStudio
import SwiftUI

struct StudioVideoHost: View {
    let model: StudioModel
    let media: [URL]
    let project: URL?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            StudioBackBar(
                title: "Video editor", subtitle: subtitle, symbol: "film.stack",
                back: {
                    model.refreshProjects()
                    model.goHome()
                }
            ) {
                if let first = media.first {
                    Menu("Quick tools") {
                        ForEach(StudioCatalog.tools(accepting: [first])) { tool in
                            if tool.style == .run {
                                Button(tool.title) { model.open(tool, with: [first]) }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            Divider()
            VideoEditorPage(media: media, project: project)
        }
        .background(DashSkin.paper(scheme == .dark))
    }

    private var subtitle: String {
        if let project { return project.deletingPathExtension().lastPathComponent }
        if media.count == 1, let first = media.first { return first.lastPathComponent }
        if media.count > 1 { return "\(media.count) clips" }
        return "New project"
    }
}
