import EdithExtensionUI
import SwiftUI

struct CleanerPage: View {
    @State var model: CleanerModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        PageScaffold(pinnedHeader: true) {
            PageHeader("Cleaner")
        } content: {
            CleanerCard(dark: scheme == .dark, model: model)
        }
        .pageRefresh(interval: { .seconds(1) }) { await model.refreshRemote() }
    }
}
