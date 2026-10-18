import EdithKit
import SwiftUI

struct SocialManagerRows: View {
    @AppStorage(AppStorageKeys.Tabs.socialManagerEnabled, store: SharedDefaults.store) private
        var enabled = false

    var body: some View {
        Section("Social profiles") {
            Text(
                "Create a profile for each person, brand or client, then add its Instagram, YouTube, X, LinkedIn, Facebook or custom website accounts. Each connected account has a separate persistent login."
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
