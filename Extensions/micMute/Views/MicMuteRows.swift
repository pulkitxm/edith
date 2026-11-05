import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct MicMuteRows: View {
    let presentation: ControlPresentation
    @AppStorage(AppStorageKeys.Mic.muteInMenuBar, store: SharedDefaults.store) private
        var inMenuBar = true

    var body: some View {
        Section {
            LabeledContent("Microphones") {
                Label(
                    presentation.state.muted ? "Muted" : "On",
                    systemImage: presentation.state.muted ? "mic.slash.fill" : "mic.fill")
            }
            LabeledContent("Shortcut") {
                HotKeyRecorderControl(keyPrefix: "micHotKey", defaultLabel: "⌘⇧M")
            }
            Text(
                "Press this shortcut in any app to mute or unmute every microphone on this Mac. Click the field to record a new one."
            )
                .settingsCaption()
            Toggle("Show in the menu bar", isOn: $inMenuBar.notifyingSettingsChange())
            Text("The menu bar icon shows the current mute state and toggles it on click.")
                .settingsCaption()
        } header: {
            Text("Mute all microphones")
        } footer: {
            if !presentation.active {
                Text("Mic Mute is not running. Turn it on in Extensions to use these controls.")
                    .settingsCaption()
            }
        }
        .disabled(!presentation.active)
        .opacity(presentation.active ? 1 : 0.5)
    }
}
