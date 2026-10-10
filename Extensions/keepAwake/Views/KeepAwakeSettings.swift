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
                Text(
                    "Keeps the Mac and display awake until turned off. Closing the lid still sleeps the Mac; use Lid Awake for that."
                )
                .foregroundStyle(.secondary)
            } header: {
                Text("Keep Awake").font(.edithText(.title)).bold()
            }
        }
        .formStyle(.grouped)
        .onChange(of: preventSleep) { synchronize() }
        .frame(minWidth: 400, minHeight: 200)
    }
}
