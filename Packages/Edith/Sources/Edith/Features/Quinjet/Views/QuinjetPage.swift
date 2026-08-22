import EdithKit
import SwiftUI

struct QuinjetPage: View {
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Quinjet")
            ContentUnavailableView(
                "Choose a project", systemImage: "arrow.triangle.branch",
                description: Text("Open a recent project or choose a folder to begin.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pageContent(compact)
        }
        .background(DashSkin.paper(scheme == .dark))
    }
}
