import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct ClipboardPage: View {
    let client: ClipboardClient
    let history: ClipboardHistoryModel
    let openPalette: () -> Void
    var presentation: ClipboardPresentation? = nil

    private var loading: Bool {
        guard let presentation, presentation.available else { return false }
        return !presentation.preferencesLoad.hasContent
            && presentation.preferencesLoad.errorMessage == nil
    }

    var body: some View {
        Group {
            if loading {
                PageSkeleton(layout: .editor)
                    .padding(UIScale.pt(20))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if let presentation, presentation.available, !presentation.preferencesLoad.hasContent,
                let error = presentation.preferencesLoad.errorMessage
            {
                PageEmptyState(
                    symbolName: "exclamationmark.triangle",
                    title: "Clipboard settings did not load",
                    message: error + " Your history is safe.",
                    primary: PageAction("Try Again", symbolName: "arrow.clockwise") {
                        Task { await presentation.refresh() }
                    })
            } else {
                Form {
                    ClipboardRows(
                        client: client, history: history, presentation: presentation,
                        openPalette: openPalette)
                }
                .deskForm()
            }
        }
        .disabled(presentation?.stopped == true)
    }
}
