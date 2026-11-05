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
                        Button("Open clipboard history", action: openPalette)
                            .buttonStyle(.edith(.primary))
                            .disabled(presentation?.available == false)
                            .help(
                                presentation?.available == false
                                    ? "Enable the Clipboard extension to open its history."
                                    : "Search and paste anything you copied recently.")
                    }
                },
                accessory: {
                    Text(
                        "Everything you copy is kept here so you can paste it again. Press \u{2303}\u{21E7}C anywhere to search it."
                    )
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
                })
        } content: {
            if presentation?.available == false {
                PageNotice(
                    "Clipboard is turned off, so nothing you copy is being recorded. Enable the extension to see your history and change these settings.",
                    tone: .warning)
            }
            if let presentation, !presentation.preferencesLoad.hasContent {
                if let error = presentation.preferencesLoad.errorMessage {
                    PageNotice(
                        error, tone: .error,
                        actions: {
                            Button("Retry") { Task { await presentation.refresh() } }
                        })
                } else if presentation.available {
                    PageSkeleton(layout: .editor)
                }
            }
            Form { ClipboardRows(client: client, history: history, presentation: presentation) }
                .formStyle(.grouped)
                .disabled(presentation.map { !$0.preferencesLoad.hasContent } ?? false)
                .opacity(presentation?.available == false ? 0.5 : 1)
        }
        .disabled(presentation?.available == false || presentation?.stopped == true)
    }
}
