import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct TerminalSettingsView: View {
    @AppStorage(TerminalSettingsKeys.fontSize, store: SharedDefaults.store)
    private var fontSize = TerminalSettings.fontSizeDefault
    @AppStorage(TerminalSettingsKeys.shell, store: SharedDefaults.store)
    private var shell = ""
    @AppStorage(TerminalSettingsKeys.loginShell, store: SharedDefaults.store)
    private var loginShell = true
    @AppStorage(TerminalSettingsKeys.startFolder, store: SharedDefaults.store)
    private var startFolder = TerminalSettings.StartFolder.home
    @AppStorage(TerminalSettingsKeys.customFolder, store: SharedDefaults.store)
    private var customFolder = ""
    @AppStorage(TerminalSettingsKeys.startupCommand, store: SharedDefaults.store)
    private var startupCommand = ""
    @AppStorage(TerminalSettingsKeys.confirmClose, store: SharedDefaults.store)
    private var confirmClose = true

    var body: some View {
        Form {
            Section {
                Stepper(value: $fontSize, in: TerminalSettings.fontSizeRange, step: 1) {
                    LabeledContent(
                        "Text size",
                        value: "\(Int(TerminalSettings.clampedFontSize(fontSize))) pt")
                }
            } footer: {
                Text("Clicks and drags reach terminal apps. Hold Shift to select and copy text.")
                    .settingsCaption()
            }
            Section {
                TextField(
                    "Shell", text: $shell,
                    prompt: Text(UserShellEnvironment.loginShell().path))
                Toggle("Start as a login shell", isOn: $loginShell)
                Picker("Start in", selection: $startFolder) {
                    ForEach(TerminalSettings.StartFolder.allCases, id: \.self) { folder in
                        Text(folder.title).tag(folder)
                    }
                }
                if startFolder == .custom {
                    TextField("Folder", text: $customFolder, prompt: Text("~/Projects"))
                }
                TextField("Startup command", text: $startupCommand, prompt: Text("None"))
                Toggle("Ask before closing a running terminal", isOn: $confirmClose)
            } footer: {
                Text("Changes apply to new tabs and restarted sessions.")
                    .settingsCaption()
            }
        }
        .edithForm()
        .frame(width: UIScale.pt(400))
        .fixedSize(horizontal: false, vertical: true)
    }
}
