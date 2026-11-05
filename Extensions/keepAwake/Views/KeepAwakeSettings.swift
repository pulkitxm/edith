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
            Section {
                Toggle("Keep awake", isOn: $preventSleep)
                    .accessibilityLabel("Keep awake")
                    .accessibilityIdentifier("keepAwake.preventSleep")
                    .accessibilityAction(.default) { preventSleep.toggle() }
                Text(
                    preventSleep
                        ? "On: your Mac and display will not go to sleep on their own. Turn this off to go back to your normal sleep settings."
                        : "Off: your Mac sleeps normally. Turn this on before a long download, build or presentation."
                )
                .settingsCaption()
                Text(
                    "Closing the lid still puts the Mac to sleep. Use Lid Awake if you need it to keep running with the lid closed."
                )
                .settingsCaption()
            } header: {
                Text("Stay awake")
            }
        }
        .edithForm()
        .onChange(of: preventSleep) { synchronize() }
    }
}
