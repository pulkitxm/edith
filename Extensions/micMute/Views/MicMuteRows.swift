import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct MicMuteRows: View {
    @Bindable var service: MicMuteEngine
    @AppStorage(AppStorageKeys.Mic.muteInMenuBar, store: SharedDefaults.store) private
        var inMenuBar = true

    var body: some View {
        Section("Control") {
            Toggle(
                "Mute microphones",
                isOn: Binding(get: { service.muted }, set: { service.setMuted($0) }))
            LabeledContent("Shortcut") {
                HotKeyRecorderControl(keyPrefix: "micHotKey", defaultLabel: "⌘⇧M")
            }
            Toggle("Show in the menu bar", isOn: $inMenuBar.notifyingSettingsChange())
            Text(
                "The shortcut and menu bar control mute every microphone. Disabling the extension restores the previous microphone controls."
            )
            .settingsCaption()
            if let error = service.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Retry") { service.retry() }
            }
        }
    }
}
