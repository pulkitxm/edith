import AppKit
import EdithExtensionUI
import SwiftUI

struct CalendarSettingsScene: View {
    let store: CalendarUIFacade

    var body: some View {
        Form {
            Section {
                LabeledContent("Source", value: "macOS Calendar app")
                LabeledContent("Access") {
                    Label(
                        store.authorized ? "Allowed" : "Not allowed yet",
                        systemImage: store.authorized
                            ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(store.authorized ? Color.green : Color.orange)
                }
                Text(
                    store.authorized
                        ? "Edith reads events from every calendar that is turned on in the Calendar app. It never edits or deletes them. Add accounts such as iCloud or Google in System Settings, Internet Accounts."
                        : "Edith cannot see your events yet. Allow access so your schedule can appear on the Calendar page, Home and the notch."
                )
                .settingsCaption()
                HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                    Spacer(minLength: 0)
                    if store.authorized {
                        Button("Open Calendar App") { store.perform(.open) }
                            .buttonStyle(.edith(.secondary))
                    } else {
                        Button("Open System Settings") {
                            if let url = CalendarUIEngine.privacySettingsURL {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.edith(.secondary))
                        Button("Allow Calendar Access") { store.perform(.permission) }
                            .buttonStyle(.edith(.primary))
                    }
                }
            } header: {
                Text("Calendar")
            }
        }
        .edithForm()
        .pageTask(cancel: store.suspend) { await store.observe() }
    }
}
