import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HostSettingsRedirect: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: UIScale.pt(1), height: UIScale.pt(1)).onAppear {
            SharedDefaults.store.set("settings", forKey: AppStorageKeys.General.mainWindowSection)
            DispatchQueue.main.async {
                for window in NSApp.windows
                where window.identifier?.rawValue.contains("Settings") == true
                    || window.title == "Edith Settings"
                { window.close() }
                openWindow(id: "main")
            }
        }
    }
}
