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
                    "Keeps the Mac and display awake until turned off. Closing the lid still sleeps the Mac; use Lid Awake for that."
                )
                .settingsCaption()
            }
        }
        .edithForm()
        .onChange(of: preventSleep) { synchronize() }
    }
}
