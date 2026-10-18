import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HerdrSettingsPage: View {
    let model: HerdrSettingsModel

    var body: some View {
        Form {
            Section("Coding agent notifications") {
                Toggle("Needs approval or an answer", isOn: flag(\.blocked))
                Toggle("Finishes its work", isOn: flag(\.finished))
                Toggle("Hits an error", isOn: flag(\.errors))
                Toggle("Looks stuck", isOn: flag(\.stuck))
                if model.settings.stuck {
                    Stepper(value: minutes, in: HerdrAttentionSettings.stuckMinutesRange) {
                        Text(
                            "Stuck after \(model.settings.stuckMinutes) minutes without screen progress"
                        )
                    }
                }
                Toggle("Open the diff when an agent finishes", isOn: flag(\.openDiff))
                Text(
                    "Edith reads an agent's screen when its state changes. Remote machines are checked every 2 minutes while no Edith window is open."
                )
                .settingsCaption()
            }
            .disabled(model.error != nil || model.loading)
            if let error = model.error {
                Section {
                    Text(error).font(.edithText(.callout))
                    Button("Retry") { Task { await model.read() } }
                }
            }
        }
        .edithForm()
        .pageTask { await model.read() }
    }

    private func flag(_ key: WritableKeyPath<HerdrAttentionSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: key] },
            set: { value in
                model.update { $0[keyPath: key] = value }
            })
    }
    private var minutes: Binding<Int> {
        Binding(
            get: { model.settings.stuckMinutes },
            set: { value in
                model.update { $0.stuckMinutes = value }
            })
    }
}
