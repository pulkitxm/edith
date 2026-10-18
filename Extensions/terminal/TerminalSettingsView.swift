import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct TerminalSettingsView: View {
    let model: TerminalTabsModel
    @State private var settings = TerminalSettings()
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.fontSize, in: TerminalSettings.fontSizeRange, step: 1) {
                    LabeledContent(
                        "Text size",
                        value: "\(Int(TerminalSettings.clampedFontSize(settings.fontSize))) pt")
                }
            } footer: {
                Text("Clicks and drags reach terminal apps. Hold Shift to select and copy text.")
                    .settingsCaption()
            }
            Section {
                TextField(
                    "Shell", text: $settings.shell,
                    prompt: Text("Default login shell"))
                Toggle("Start as a login shell", isOn: $settings.loginShell)
                Picker("Start in", selection: $settings.startFolder) {
                    ForEach(TerminalSettings.StartFolder.allCases, id: \.self) { folder in
                        Text(folder.title).tag(folder)
                    }
                }
                if settings.startFolder == .custom {
                    TextField("Folder", text: $settings.customFolder, prompt: Text("~/Projects"))
                }
                TextField("Startup command", text: $settings.startupCommand, prompt: Text("None"))
                Toggle("Ask before closing a running terminal", isOn: $settings.confirmClose)
            } footer: {
                Text("Changes apply to new tabs and restarted sessions.")
                    .settingsCaption()
            }
        }
        .edithForm()
        .onAppear {
            settings = model.settings; loaded = true
        }
        .onChange(of: settings) { _, next in
            guard loaded else { return }
            saveTask?.cancel()
            saveTask = Task {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                await model.savePreferences(next)
            }
        }
        .onDisappear {
            saveTask?.cancel()
            if loaded, settings != model.settings { model.queuePreferences(settings) }
        }
        .frame(width: UIScale.pt(400))
        .fixedSize(horizontal: false, vertical: true)
    }
}
