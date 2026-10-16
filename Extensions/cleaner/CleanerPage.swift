import EdithExtensionUI
import SwiftUI

struct CleanerPage: View {
    @State var model: CleanerModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        PageWorkspace {
            PageHeader(
                "Cleaner",
                accessory: {
                    Text("Find reclaimable space and remove it after review.")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                })
            Divider()
        } content: {
            ScrollView {
                CleanerCard(dark: scheme == .dark, framed: false, model: model)
                    .pageContent(compact)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pageTask {
            while !Task.isCancelled {
                await model.refreshRemote()
                guard !Task.isCancelled else { return }
                let interval: Duration = model.scanning ? .milliseconds(150) : .seconds(1)
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }
}
