import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct ClipboardPage: View {
    let client: ClipboardClient
    let history: ClipboardHistoryModel
    let openPalette: () -> Void
    @AppStorage(AppStorageKeys.Clipboard.enabled, store: SharedDefaults.store) private var enabled =
        false

    var body: some View {
        PageWorkspace {
            PageHeader("Clipboard") {
                Toggle("Capture copies", isOn: $enabled.notifyingSettingsChange())
                    .toggleStyle(.switch)
                Button("Open clipboard", action: openPalette)
                    .buttonStyle(.edith(.secondary))
            }
        } content: {
            Form { ClipboardRows(client: client, history: history) }
                .formStyle(.grouped)
        }
    }
}
