import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct MicMuteRows: View {
    let presentation: ControlPresentation
    @AppStorage(AppStorageKeys.Mic.muteInMenuBar, store: SharedDefaults.store) private
        var inMenuBar = true

    var body: some View {
        ControlSettingsIssueSection()
        Section {
            if presentation.active {
                LabeledContent("Microphones") {
                    Label(
                        presentation.state.muted ? "Muted" : "Live",
                        systemImage: presentation.state.muted ? "mic.slash.fill" : "mic.fill"
                    )
                    .foregroundStyle(presentation.state.muted ? Color.red : Color.secondary)
                }
            }
            LabeledContent {
                HotKeyRecorderControl(keyPrefix: "micHotKey", defaultLabel: "⌘⇧M")
            } label: {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("Shortcut")
                    Text(
                        "Mutes or unmutes every microphone from any app. Click to record a new one."
                    )
                    .settingsCaption()
                }
            }
            .disabled(!presentation.active)
            Toggle(isOn: $inMenuBar.notifyingSettingsChange()) {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("Show in the menu bar")
                    Text("The icon shows whether you are muted. Click it to switch.")
                        .settingsCaption()
                }
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
