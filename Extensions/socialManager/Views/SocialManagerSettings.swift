import EdithExtensionUI
import SwiftUI

struct SocialManagerSettings: View {
    var body: some View {
        Form {
            Section("Social profiles") {
                Text(
                    "Create a profile for each person, brand or client, then add its Instagram, YouTube, X, LinkedIn, Facebook or custom website accounts. Each connected account has a separate persistent login."
                )
                .settingsCaption()
                Text(
                    "Open accounts as tabs, or use Side by side to combine accounts from any platform in resizable panes."
                )
                .settingsCaption()
            }
        }
        .edithForm()
    }
}
