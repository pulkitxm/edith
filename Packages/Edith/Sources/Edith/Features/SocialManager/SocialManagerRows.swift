import EdithKit
import SwiftUI

struct SocialManagerRows: View {
    @AppStorage(AppStorageKeys.Tabs.socialManagerEnabled, store: SharedDefaults.store) private
        var enabled = false

    var body: some View {
        Section("Social accounts") {
            Text(
                "Add Instagram, Facebook, X or any HTTPS website. Each named account has a persistent, separate browser session on this Mac."
            )
            .settingsCaption()
            Text(
                "Open accounts as tabs, or use Side by side to combine accounts from any platform in resizable panes."
            )
            .settingsCaption()
            Button("Open Social Manager") { SectionWindow.focusOrSelect(.socialManager) }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
