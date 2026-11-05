import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct KeepAwakeSettings: View {
    @AppStorage private var preventSleep: Bool
    let synchronize: @MainActor () -> Void

    init(defaults: UserDefaults, synchronize: @escaping @MainActor () -> Void) {
        _preventSleep = AppStorage(wrappedValue: false, "preventSleep", store: defaults)
        self.synchronize = synchronize
    }

    var body: some View {
        Form {
            SettingsIssueSection()
            Section {
                Toggle(isOn: $preventSleep.notifyingSettingsChange()) {
                    Text("Keep awake")
                    Text(
                        preventSleep
                            ? "On. Your Mac and display stay awake until you turn this off."
                            : "Off. Your Mac follows its normal sleep settings.")
                }
                .accessibilityLabel("Keep awake")
                .accessibilityIdentifier("keepAwake.preventSleep")
                .accessibilityAction(.default) { preventSleep.toggle() }
            } header: {
                Text("Stay awake")
            } footer: {
                Text(
                    "Turn this on before a long download, build or presentation. Closing the lid still puts the Mac to sleep; use Lid Awake to keep it running with the lid closed."
                )
                .settingsCaption()
            }
        }
        .settingsForm()
        .onChange(of: preventSleep) { synchronize() }
    }
}
