import EdithExtensionUI
import SwiftUI

struct QuinjetSettingsPage: View {
    let model: QuinjetSettingsModel

    var body: some View {
        Form {
            Section("Launch") {
                Picker("Terminal", selection: terminal) {
                    ForEach(QuinjetTerminal.allCases) { option in
                        Label(option.label, systemImage: option.icon).tag(option.rawValue)
                            .disabled(option == .cmux && model.state?.cmuxAvailable != true)
                    }
                }
                Picker("Theme", selection: theme) {
                    Text("App theme").tag(QuinjetThemePreference.app)
                    ForEach(model.state?.themes ?? [], id: \.self) { value in
                        Text(QuinjetTheme(rawValue: value)?.label ?? value).tag(value)
                    }
                }
                if let error = model.error {
                    Text(error).font(.edithText(.caption)).foregroundStyle(.red)
                    Button("Retry") { Task { await model.read() } }
                }
            }
            .disabled(model.loading)
        }
        .edithForm()
        .pageTask { await model.read() }
    }

    private var terminal: Binding<String> {
        Binding(
            get: { model.state?.preference.terminal ?? QuinjetTerminal.embedded.rawValue },
            set: model.setTerminal)
    }
    private var theme: Binding<String> {
        Binding(
            get: { model.state?.preference.theme ?? QuinjetThemePreference.app },
            set: model.setTheme)
    }
}
