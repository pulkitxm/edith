import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct ClipboardPage: View {
    let client: ClipboardClient
    let history: ClipboardHistoryModel
    let openPalette: () -> Void
    var presentation: ClipboardPresentation? = nil

    var body: some View {
        PageWorkspace {
            PageHeader(
                "Clipboard",
                trailing: {
                    HStack(spacing: UIScale.pt(12)) {
                        Button("Open clipboard", action: openPalette)
                            .buttonStyle(.edith(.secondary))
                    }
                })
        } content: {
            if presentation?.available == false {
                Text(
                    "Clipboard is disabled. Enable the extension to view your history and change settings."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary).padding()
            }
            if let presentation, !presentation.preferencesLoad.hasContent {
                if let error = presentation.preferencesLoad.errorMessage {
                    PageNotice(
                        error, tone: .error,
                        actions: {
                            Button("Retry") { Task { await presentation.refresh() } }
                        })
                } else if presentation.available {
                    LoadingIndicator().padding()
                }
            }
            Form { ClipboardRows(client: client, history: history, presentation: presentation) }
                .formStyle(.grouped)
                .disabled(presentation.map { !$0.preferencesLoad.hasContent } ?? false)
        }
        .disabled(presentation?.available == false || presentation?.stopped == true)
    }
}
