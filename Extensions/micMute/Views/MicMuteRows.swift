import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct MicMuteRows: View {
    let presentation: ControlPresentation
    @AppStorage(AppStorageKeys.Mic.muteInMenuBar, store: SharedDefaults.store) private
        var inMenuBar = true

    var body: some View {
        Section {
            LabeledContent("Shortcut") {
                HotKeyRecorderControl(keyPrefix: "micHotKey", defaultLabel: "⌘⇧M")
            }
            Text("Use this shortcut to mute or unmute every microphone system-wide.")
                .settingsCaption()
            Toggle("Show in the menu bar", isOn: $inMenuBar.notifyingSettingsChange())
            Text("The menu bar icon shows the current mute state and toggles it on click.")
                .settingsCaption()
        }
        .disabled(!presentation.active)
        .opacity(presentation.active ? 1 : 0.5)
    }
}
