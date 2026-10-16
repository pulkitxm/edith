import EdithExtensionUI
import SwiftUI

struct CalendarSettingsScene: View {
    let store: CalendarUIFacade

    var body: some View {
        Form {
            Section("Calendar") {
                LabeledContent("Source", value: "macOS Calendar")
                Text("Your agenda appears in Edith after Calendar access is granted.")
                    .settingsCaption()
                HStack {
                    Button("Open Calendar app") { store.perform(.open) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
