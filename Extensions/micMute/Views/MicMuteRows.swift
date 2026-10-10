import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct MicMuteRows: View {
    let presentation: ControlPresentation
    @AppStorage(AppStorageKeys.Mic.muteInMenuBar, store: SharedDefaults.store) private
        var inMenuBar = true

    var body: some View {
        Section("Control") {
            Toggle(
                "Mute microphones",
                isOn: Binding(
                    get: { presentation.state.muted },
                    set: { presentation.perform($0 ? "mute" : "unmute") })
            )
            .disabled(!presentation.active)
            LabeledContent("Shortcut") {
                HotKeyRecorderControl(keyPrefix: "micHotKey", defaultLabel: "⌘⇧M")
            }
            Toggle("Show in the menu bar", isOn: $inMenuBar.notifyingSettingsChange())
            Text(
                "The shortcut and menu bar control mute every microphone. Disabling the extension restores the previous microphone controls."
            )
            .settingsCaption()
            if let error = presentation.state.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Retry") { presentation.perform("retry") }
            }
        }
    }
}
