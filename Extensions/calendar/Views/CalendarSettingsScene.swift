import EdithExtensionUI
import SwiftUI

struct CalendarSettingsScene: View {
    let store: CalendarUIFacade

    var body: some View {
        Form {
            Section("Calendar") {
                LabeledContent("Source", value: "macOS Calendar")
                LabeledContent("Access", value: store.authorized ? "Allowed" : "Not allowed yet")
                Text(
                    store.authorized
                        ? "Edith reads events from every calendar that is turned on in the Calendar app. It never edits or deletes them. Add accounts such as iCloud or Google in System Settings, Internet Accounts."
                        : "Edith cannot see your events yet. Allow access so your schedule can appear on the Calendar page, Home and the notch."
                )
                .settingsCaption()
                HStack {
                    if !store.authorized {
                        Button("Allow Calendar Access") { store.perform(.permission) }
                            .buttonStyle(.edith(.primary))
                    }
                    Button("Open Calendar app") { store.perform(.open) }
                }
            }
        }
        .formStyle(.grouped)
        .pageTask(cancel: store.suspend) { await store.observe() }
    }
}
