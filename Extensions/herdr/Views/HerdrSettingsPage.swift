import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HerdrSettingsPage: View {
    let model: HerdrSettingsModel

    var body: some View {
        PageScaffold {
            PageHeader("Herdr")
        } content: {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                PageSectionHeader("Coding agent notifications")
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    Toggle("Needs approval or an answer", isOn: flag(\.blocked))
                    Toggle("Finishes its work", isOn: flag(\.finished))
                    Toggle("Hits an error", isOn: flag(\.errors))
                    Toggle("Looks stuck", isOn: flag(\.stuck))
                    if model.settings.stuck {
                        Stepper(value: minutes, in: HerdrAttentionSettings.stuckMinutesRange) {
                            Text(
                                "Stuck after \(model.settings.stuckMinutes) minutes without screen progress"
                            ).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Toggle("Open the diff when an agent finishes", isOn: flag(\.openDiff))
                    Toggle("Monitor terminal attention", isOn: flag(\.monitoring))
                    Text("Edith reads an agent's screen when its state changes.")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }.disabled(model.error != nil)
                if let error = model.error {
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        Text(error).font(.edithText(.callout))
                        Button("Retry") { Task { await model.read() } }
                    }
                }
            }
            .font(.edithText(.body))
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.loading)
        }
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
