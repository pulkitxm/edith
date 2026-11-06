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
                PageSkeleton(layout: .form)
            } else if let presentation, presentation.available,
                !presentation.preferencesLoad.hasContent,
                let error = presentation.preferencesLoad.errorMessage
            {
                PageEmptyState(
                    icon: .warning,
                    title: "Clipboard settings did not load",
                    message: error + " Your history is safe.",
                    primary: PageAction("Try Again", icon: .refresh) {
                        Task { await presentation.refresh() }
                    })
            } else {
                Form {
                    ClipboardRows(
                        client: client, history: history, presentation: presentation,
                        openPalette: openPalette)
                }
                .settingsForm()
            }
        }
        .disabled(presentation?.stopped == true)
    }
}
