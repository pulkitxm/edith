import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct MicMuteRows: View {
    let presentation: ControlPresentation
    @AppStorage(AppStorageKeys.Mic.muteInMenuBar, store: SharedDefaults.store) private
        var inMenuBar = true

    var body: some View {
        SettingsIssueSection()
        Section {
            if presentation.active {
                SettingsRow("Microphones") {
                    Label(
                        presentation.state.muted ? "Muted" : "Live",
                        edith: presentation.state.muted ? .micMute : .mic
                    )
                    .foregroundStyle(presentation.state.muted ? Color.red : Color.secondary)
                }
            }
            SettingsShortcutRow(
                keyPrefix: "micHotKey", defaultLabel: "⌘⇧M",
                purpose: "Mutes or unmutes every microphone from any app."
            )
            .disabled(!presentation.active)
            Toggle(isOn: $inMenuBar.notifyingSettingsChange()) {
                Text("Show in the menu bar")
                Text("The icon shows whether you are muted. Click it to switch.")
            }
            .disabled(!presentation.active)
        } header: {
            Text("Mute all microphones")
        } footer: {
            if !presentation.active {
                Text("Mic Mute is turned off. Turn it on in Extensions to use these controls.")
                    .settingsCaption()
            }
        }
    }
}
