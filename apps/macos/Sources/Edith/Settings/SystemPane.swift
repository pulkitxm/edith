import EdithKit
import SwiftUI

struct SystemPane: View {
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var enabled = true
    @AppStorage("preventSleep", store: SharedDefaults.store) private var preventSleep = false

    var body: some View {
        Form {
            Section {
                Toggle("System tools", isOn: $enabled)
                    .pointerCursor()
                Text(
                    "Prevent-sleep toggle and the keyboard-cleaning lock, from the menu bar panel."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Toggle("Prevent sleep", isOn: $preventSleep)
                        .pointerCursor()
                    InfoDot(
                        "Keeps your Mac awake until you turn this off again, even with the lid closed on power."
                    )
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
        .formStyle(.grouped)
        .navigationTitle("System")
    }
}
