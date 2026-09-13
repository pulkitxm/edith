import EdithKit
import SwiftUI

struct ScratchpadRows: View {
    @AppStorage(AppStorageKeys.Scratchpad.enabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(AppStorageKeys.Scratchpad.alwaysOnTop, store: SharedDefaults.store) private
        var alwaysOnTop = true
    @AppStorage(AppStorageKeys.Scratchpad.dismissOnDeactivate, store: SharedDefaults.store) private
        var dismissOnDeactivate = true
    @AppStorage(AppStorageKeys.Scratchpad.retention, store: SharedDefaults.store) private
        var retention = ScratchpadRetention.never.rawValue
    @AppStorage(AppStorageKeys.Tabs.companionEnabled, store: SharedDefaults.store) private
        var companionEnabled = false

    var body: some View {
        Section("Open") {
            LabeledContent("Global shortcut") {
                HotKeyRecorderControl(keyPrefix: "scratchpadHotKey", defaultLabel: "⌃⌥N")
            }
            Button {
                IPC.post(IPC.Name.requestScratchpadPanel)
            } label: {
                Label("Open Scratchpad", systemImage: "note.text")
            }
            Text("The shortcut uses macOS hotkey registration and needs no privacy permission.")
                .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        Section("Window") {
            Toggle(
                "Always on top",
                isOn: $alwaysOnTop.configured(AppStorageKeys.Scratchpad.alwaysOnTop))
            Toggle(
                "Dismiss when inactive",
                isOn: $dismissOnDeactivate.configured(
                    AppStorageKeys.Scratchpad.dismissOnDeactivate))
            Text(
                "Keep the pad floating while you work, or let it step aside when focus moves elsewhere."
            )
            .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        Section("Automatic clearing") {
            Picker(
                "Quiet period",
                selection: $retention.configured(AppStorageKeys.Scratchpad.retention)
            ) {
                ForEach(ScratchpadRetention.allCases, id: \.self) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            Text("Each pad clears only after it has gone unedited for the selected period.")
                .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        Section("Companion") {
            if companionEnabled {
                Label(
                    "Remember in Companion is available in the Scratchpad panel.",
                    systemImage: "brain.head.profile"
                )
                .settingsCaption()
            } else {
                Text(
                    "Scratchpad works independently. Enable Companion to promote a finished pad into memory with a deliberate action."
                )
                .settingsCaption()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
