import AppKit
import EdithKit
import SwiftUI

struct AddMachineSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case sshConfig
        case manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sshConfig: return "From SSH config"
            case .manual: return "Enter details"
            }
        }
    }

    enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    struct Secrets {
        var login: String?
        var sudo: String?
        var forgetSudo = false
    }

    var editing: Machine?
    let onSave: (Machine, Secrets) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var mode = Mode.sshConfig
    @State private var configHosts: [SSHConfigHost] = []
    @State private var selectedAlias: String?
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authKind = AuthKind.agent
    @State private var keyPath = ""
    @State private var secret = ""
    @State private var sudoPassword = ""
    @State private var sudoPasswordStored = false
    @State private var forgetSudoPassword = false
    @State private var testState = TestState.idle
    @State private var testTask: Task<Void, Never>?

    private var dark: Bool { scheme == .dark }

    enum AuthKind: String, CaseIterable, Identifiable {
        case agent
        case key
        case password

        var id: String { rawValue }

        var title: String {
            switch self {
            case .agent: return "SSH agent or default key"
            case .key: return "Key file"
            case .password: return "Password"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    if editing == nil {
                        Picker("", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if mode == .sshConfig, editing == nil {
                        configSection
                    } else {
                        manualSection
                    }
                    authSection
                    sudoSection
                    testSection
                }
                .padding(UIScale.pt(20))
            }
            Divider()
            footerBar
        }
        .frame(width: UIScale.pt(560), height: UIScale.pt(620))
        .background(DashSkin.paper(dark))
        .onAppear(perform: load)
        .onDisappear { testTask?.cancel() }
    }

    private var headerBar: some View {
        HStack {
            Text(editing == nil ? "Add a machine" : "Edit machine")
                .font(DashSkin.serif(20))
                .foregroundStyle(DashSkin.ink(dark))
            Spacer()
        }
        .padding(.horizontal, UIScale.pt(20))
        .padding(.vertical, UIScale.pt(14))
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            eyebrow("HOSTS IN ~/.SSH/CONFIG")
            if configHosts.isEmpty {
                Text("No hosts found in ~/.ssh/config. Switch to Enter details instead.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            VStack(spacing: UIScale.pt(0)) {
                ForEach(configHosts) { configHost in
                    Button {
                        select(configHost)
                    } label: {
                        HStack(spacing: UIScale.pt(10)) {
                            Image(
                                systemName: selectedAlias == configHost.alias
                                    ? "largecircle.fill.circle" : "circle"
                            )
                            .foregroundStyle(
                                selectedAlias == configHost.alias
                                    ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                                Text(configHost.alias)
                                    .font(.system(size: UIScale.pt(12.5), weight: .medium))
                                    .foregroundStyle(DashSkin.ink(dark))
                                Text(configHost.displayTarget)
                                    .font(DashSkin.mono(10.5))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, UIScale.pt(7))
                        .padding(.horizontal, UIScale.pt(9))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    if configHost.id != configHosts.last?.id { Divider().opacity(0.3) }
                }
            }
            .widgetBar(cornerRadius: 10, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
            labelledField("Display name", text: $name, placeholder: "Linux laptop")
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            eyebrow("CONNECTION")
            labelledField("Display name", text: $name, placeholder: "Linux laptop")
            labelledField("Host", text: $host, placeholder: "192.168.1.12")
            HStack(spacing: UIScale.pt(10)) {
                labelledField("User", text: $username, placeholder: "pulkit")
                labelledField("Port", text: $port, placeholder: "22")
                    .frame(width: UIScale.pt(110))
            }
        }
    }

    private var authSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            eyebrow("AUTHENTICATION")
            Picker("", selection: $authKind) {
                ForEach(AuthKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if authKind == .key {
                HStack(spacing: UIScale.pt(8)) {
                    labelledField("Key file", text: $keyPath, placeholder: "~/.ssh/id_ed25519")
                    Button("Choose…") { chooseKey() }
                        .pointerCursor()
                }
                secureField("Passphrase (optional)", text: $secret)
            }
            if authKind == .password {
                secureField("Password", text: $secret)
                Text("Stored in your Mac's Keychain and never passed on a command line.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            if authKind == .agent {
                Text("Uses your SSH agent and the keys ssh already loads for this host.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }

    private var sudoSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            eyebrow("PRIVILEGED ACTIONS")
            if sudoPasswordStored, sudoPassword.isEmpty, !forgetSudoPassword {
                HStack(spacing: UIScale.pt(10)) {
                    Text("A sudo password is saved for this machine.")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    Button("Forget") { forgetSudoPassword = true }
                        .pointerCursor()
                }
            }
            secureField("Sudo password (optional)", text: $sudoPassword)
            Text(
                "Shut down, restart and unit actions need root. Without this, Edith can only try "
                    + "passwordless sudo. Stored in your Mac's Keychain and sent on the command's "
                    + "standard input, never on a command line."
            )
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(DashSkin.inkFaint(dark))
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(10)) {
                Button {
                    runTest()
                } label: {
                    if testState == .testing {
                        HStack(spacing: UIScale.pt(6)) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("Testing…")
                        }
                    } else {
                        Text("Test connection")
                    }
                }
                .disabled(!isValid || testState == .testing)
                .pointerCursor()
                Spacer(minLength: 0)
            }
            switch testState {
            case let .success(message):
                statusLine(message, symbol: "checkmark.circle.fill", color: DashSkin.ok)
            case let .failure(message):
                statusLine(message, symbol: "exclamationmark.triangle.fill", color: DashSkin.danger)
            default:
                EmptyView()
            }
        }
    }

    private func statusLine(_ message: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(7)) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(message)
                .font(.system(size: UIScale.pt(11.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UIScale.pt(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
    }

    private var footerBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .pointerCursor()
            Spacer()
            Button(editing == nil ? "Add machine" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
                .pointerCursor()
        }
        .padding(UIScale.pt(16))
    }

    private func labelledField(
        _ title: String, text: Binding<String>, placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(title)
                .font(.system(size: UIScale.pt(11), weight: .medium))
                .foregroundStyle(DashSkin.inkFaint(dark))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(title)
                .font(.system(size: UIScale.pt(11), weight: .medium))
                .foregroundStyle(DashSkin.inkFaint(dark))
            SecureField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if mode == .sshConfig, editing == nil { return selectedAlias != nil }
        return !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() {
        configHosts = SSHConfigFile.concreteHosts()
        guard let editing else {
            if configHosts.isEmpty { mode = .manual }
            return
        }
        mode = .manual
        sudoPasswordStored = SudoPassword.isStored(machineID: editing.id)
        name = editing.name
        host = editing.host
        port = String(editing.port)
        username = editing.username
        if case let .sshConfigAlias(alias) = editing.source {
            selectedAlias = alias
        }
        switch editing.auth {
        case .agent: authKind = .agent
        case let .keyFile(path, _):
            authKind = .key
            keyPath = path
        case .password: authKind = .password
        }
    }

    private func select(_ configHost: SSHConfigHost) {
        selectedAlias = configHost.alias
        host = configHost.hostName ?? configHost.alias
        username = configHost.user ?? ""
        port = String(configHost.port ?? 22)
        if name.isEmpty { name = configHost.alias }
        if let identity = configHost.identityFile {
            keyPath = identity
        }
        testState = .idle
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keyPath = url.path
    }

    private func makeMachine() -> Machine {
        let auth: MachineAuth
        switch authKind {
        case .agent: auth = .agent
        case .key:
            auth = .keyFile(
                path: keyPath,
                hasPassphrase: !secret.isEmpty || (editing?.auth.usesAskpass ?? false))
        case .password: auth = .password
        }
        let source: MachineSource
        if mode == .sshConfig, let selectedAlias {
            source = .sshConfigAlias(selectedAlias)
        } else if let editing, case let .sshConfigAlias(alias) = editing.source {
            source = .sshConfigAlias(alias)
        } else {
            source = .manual
        }
        return Machine(
            id: editing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 22,
            username: username.trimmingCharacters(in: .whitespaces), auth: auth, source: source,
            wakeMACAddress: editing?.wakeMACAddress, createdAt: editing?.createdAt ?? Date())
    }

    private func runTest() {
        testTask?.cancel()
        testState = .testing
        let machine = makeMachine()
        let secretValue = secret
        testTask = Task {
            if !secretValue.isEmpty {
                let kind: MachineSecretKind = machine.auth == .password ? .password : .passphrase
                MachineSecrets.set(secretValue, machineID: machine.id, kind: kind)
            }
            let connection = SSHConnection(machine: machine)
            do {
                try await connection.connect()
                let result = try await connection.run(
                    "uname -sr; id -un; command -v docker >/dev/null 2>&1 && echo docker-yes",
                    timeout: 20)
                await connection.disconnect()
                guard !Task.isCancelled else { return }
                let lines = result.stdoutText.split(separator: "\n").map(String.init)
                var message = "Connected"
                if let kernel = lines.first { message += " to \(kernel)" }
                if lines.count > 1 { message += " as \(lines[1])" }
                if lines.contains("docker-yes") { message += ". Docker found." }
                testState = .success(message)
            } catch {
                await connection.disconnect()
                guard !Task.isCancelled else { return }
                testState = .failure(error.localizedDescription)
            }
        }
    }

    private func save() {
        let machine = makeMachine()
        onSave(
            machine,
            Secrets(
                login: secret.isEmpty ? nil : secret,
                sudo: sudoPassword.isEmpty ? nil : sudoPassword,
                forgetSudo: forgetSudoPassword && sudoPassword.isEmpty))
        dismiss()
    }
}
