import AppKit
import EdithExtensionSupport
import EdithExtensionUI
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
    var loadConfiguration: (@MainActor () async throws -> MachineUIConfigurationState)?
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
    @State private var sshClipboardEnabled = false
    @State private var testState = TestState.idle
    @State private var testTask: Task<Void, Never>?
    @State private var showsMoreOptions = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dark: Bool { scheme == .dark }

    enum AuthKind: String, CaseIterable, Identifiable {
        case agent
        case key
        case password

        var id: String { rawValue }

        var title: String {
            switch self {
            case .agent: return "SSH agent"
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
                VStack(alignment: .leading, spacing: UIScale.pt(24)) {
                    VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                        if editing == nil {
                            EdithSegmentedPicker(
                                "", selection: $mode, options: Mode.allCases, label: { $0.title }
                            )
                            .labelsHidden()
                        }
                        if mode == .sshConfig, editing == nil {
                            configSection
                        } else {
                            manualSection
                        }
                    }
                    authSection
                    moreOptions
                    testSection
                }
                .padding(UIScale.pt(24))
                .machinePrivacyCover()
            }
            Divider()
            footerBar
        }
        .frame(width: PresentationMetrics.width(560), height: PresentationMetrics.height(690))
        .background(DashSkin.paper(dark))
        .pageTask { await load() }
        .onDisappear { testTask?.cancel() }
    }

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(editing == nil ? "Add a machine" : "Edit machine")
                .font(DashSkin.heading(20))
                .foregroundStyle(DashSkin.ink(dark))
                .accessibilityAddTraits(.isHeader)
            Text(
                editing == nil
                    ? "Connect any computer you can reach over SSH. You can change these details later."
                    : "Changes apply the next time Edith connects to this machine."
            )
            .font(.edithText(.callout))
            .foregroundStyle(DashSkin.inkSoft(dark))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, UIScale.pt(24))
        .padding(.top, UIScale.pt(20))
        .padding(.bottom, UIScale.pt(16))
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            if configHosts.isEmpty {
                helpText("No hosts found in ~/.ssh/config. Choose Enter details instead.")
            } else {
                helpText("Pick a host you already set up in ~/.ssh/config.")
            }
            EdithRowList(configHosts) { configHost in
                EdithRowButton {
                    select(configHost)
                } label: {
                    HStack(spacing: UIScale.pt(10)) {
                        EdithIconView(selectedAlias == configHost.alias ? .radioOn : .ring)
                            .foregroundStyle(
                                selectedAlias == configHost.alias
                                    ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                            Text(configHost.alias)
                                .font(.edithText(.body).weight(.medium))
                                .foregroundStyle(DashSkin.ink(dark))
                            Text(configHost.displayTarget)
                                .font(.edithText(.caption, design: .monospaced))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            labelledField("Display name", text: $name, placeholder: "Build server")
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            labelledField("Display name", text: $name, placeholder: "Build server")
            labelledField("Address", text: $host, placeholder: "192.168.1.12 or server.example.com")
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                labelledField("Username", text: $username, placeholder: "admin")
                labelledField("Port", text: $port, placeholder: "22")
                    .frame(width: UIScale.pt(96))
            }
        }
    }

    private var authSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            PageCapsLabel("Sign in with")
            EdithSegmentedPicker(
                "", selection: $authKind, options: AuthKind.allCases, label: { $0.title }
            )
            .labelsHidden()
            if authKind == .key {
                HStack(alignment: .bottom, spacing: UIScale.pt(8)) {
                    labelledField("Key file", text: $keyPath, placeholder: "~/.ssh/id_ed25519")
                    Button("Choose…") { chooseKey() }
                        .buttonStyle(.edith(.secondary))
                }
                secureField("Passphrase (optional)", text: $secret)
            }
            if authKind == .password {
                secureField("Password", text: $secret)
                helpText("Stored in your Mac's Keychain and never passed on a command line.")
            }
            if authKind == .agent {
                helpText(
                    "Uses your SSH agent and the keys ssh already loads for this host. Pick this if ssh works in Terminal without a password."
                )
            }
        }
    }

    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            Button {
                withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                    showsMoreOptions.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                    EdithIconView(.chevronRight)
                        .font(.edithText(.caption).weight(.semibold))
                        .rotationEffect(.degrees(showsMoreOptions ? 90 : 0))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text("More options")
                            .font(.edithText(.body).weight(.medium))
                            .foregroundStyle(DashSkin.ink(dark))
                        Text("Clipboard sync and a sudo password. Optional.")
                            .font(.edithText(.caption))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .accessibilityValue(showsMoreOptions ? "Expanded" : "Collapsed")
            if showsMoreOptions {
                sshClipboardSection
                sudoSection
            }
        }
    }

    private var sudoSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            PageCapsLabel("Admin actions")
            if sudoPasswordStored, sudoPassword.isEmpty, !forgetSudoPassword {
                HStack(spacing: UIScale.pt(8)) {
                    helpText("A sudo password is saved for this machine.")
                    Button("Forget") { forgetSudoPassword = true }
                        .buttonStyle(.edith(.secondary))
                }
            }
            secureField("Sudo password", text: $sudoPassword)
            helpText(
                "Shut down, restart and service actions need root. Without this, Edith can only try "
                    + "passwordless sudo. Stored in your Mac's Keychain and sent on the command's "
                    + "standard input, never on a command line.")
        }
    }

    private var sshClipboardSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            PageCapsLabel("Clipboard")
            Toggle("Sync clipboard with this machine", isOn: $sshClipboardEnabled)
                .toggleStyle(.edithSwitch)
                .font(.edithText(.body))
                .disabled(authKind != .agent)
            helpText(sshClipboardHelp)
        }
    }

    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.edithText(.caption))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sshClipboardHelp: String {
        if authKind != .agent {
            return "Clipboard sync requires passwordless SSH through your SSH agent or SSH config."
        }
        if sshClipboardEnabled {
            return
                "Saving installs or repairs the background service on both machines and starts syncing automatically."
        }
        return "Copy on one machine and paste on the other. Off by default."
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(spacing: UIScale.pt(12)) {
                Button {
                    runTest()
                } label: {
                    Text("Test connection")
                }
                .buttonStyle(.edith(.secondary))
                .disabled(!isValid || testState == .testing)
                .fixedSize()
                helpText(
                    isValid ? "Checks the address and sign-in before you save." : missingDetails)
                Spacer(minLength: 0)
            }
            switch testState {
            case .testing:
                SkeletonGroup {
                    HStack(alignment: .top, spacing: UIScale.pt(7)) {
                        SkeletonBlock(width: 15, height: 15, corner: 7.5)
                        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                            SkeletonBlock(width: 116, height: 10, corner: 2)
                            SkeletonBlock(width: 208, height: 9, corner: 2)
                        }
                    }
                    .padding(UIScale.pt(10))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        DashSkin.accent(dark).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
                }
                .accessibilityLabel("Testing connection")
            case let .success(message):
                statusLine(message, icon: .success, color: DashSkin.ok)
            case let .failure(message):
                statusLine(message, icon: .warning, color: DashSkin.danger)
            default:
                EmptyView()
            }
        }
    }

    private func statusLine(_ message: String, icon: EdithIcon, color: Color) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(7)) {
            EdithIconView(icon).foregroundStyle(color)
            Text(message)
                .font(.edithText(.callout))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UIScale.pt(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

    private var footerBar: some View {
        HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.edith(.secondary))
                .keyboardShortcut(.cancelAction)
            Button(editing == nil ? "Add machine" : "Save") { save() }
                .buttonStyle(.edith(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
                .help(isValid ? "" : missingDetails)
        }
        .padding(.horizontal, UIScale.pt(24))
        .padding(.vertical, UIScale.pt(16))
    }

    private func labelledField(
        _ title: String, text: Binding<String>, placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(title)
                .font(.edithText(.subheadline).weight(.medium))
                .foregroundStyle(DashSkin.inkSoft(dark))
            EdithTextField(placeholder: placeholder, text: text)
        }
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(title)
                .font(.edithText(.subheadline).weight(.medium))
                .foregroundStyle(DashSkin.inkSoft(dark))
            EdithSecureField(placeholder: "", text: text)
                .accessibilityLabel(title)
        }
    }

    private var missingDetails: String {
        mode == .sshConfig && editing == nil
            ? "Pick a host and give it a name first."
            : "Add a name and an address first."
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if mode == .sshConfig, editing == nil { return selectedAlias != nil }
        return !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() async {
        let loader =
            loadConfiguration
            ?? MachinesModel.shared.uiClient.map { client in
                { try await client.configuration() }
            }
        guard let loader else {
            testState = .failure(MachineUIError.unavailable.localizedDescription)
            return
        }
        do {
            let configuration = try await loader()
            guard !Task.isCancelled else { return }
            configHosts = configuration.hosts
            sudoPasswordStored =
                editing.map { configuration.sudoPasswordStored.contains($0.id) } ?? false
            if editing == nil, configHosts.isEmpty { mode = .manual }
        } catch {
            guard !Task.isCancelled else { return }
            testState = .failure(error.localizedDescription)
        }
        guard let editing else { return }
        showsMoreOptions = editing.sshClipboardEnabled || sudoPasswordStored
        mode = .manual
        name = editing.name
        host = editing.host
        port = String(editing.port)
        username = editing.username
        sshClipboardEnabled = editing.sshClipboardEnabled
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
            sshClipboardEnabled: authKind == .agent && sshClipboardEnabled,
            wakeMACAddress: editing?.wakeMACAddress, createdAt: editing?.createdAt ?? Date())
    }

    private func runTest() {
        testTask?.cancel()
        testState = .testing
        let machine = makeMachine()
        let secretValue = secret
        testTask = Task {
            guard let client = MachinesModel.shared.uiClient else {
                testState = .failure(MachineUIError.unavailable.localizedDescription)
                return
            }
            do {
                let output = try await client.probe(
                    machine,
                    secrets: MachineSecretChanges(
                        login: secretValue.isEmpty ? nil : secretValue))
                guard !Task.isCancelled else { return }
                let facts = MachineConnectionProbe.parse(output)
                var message = "Connected"
                if !facts.system.isEmpty { message += " to \(facts.system)" }
                if !facts.user.isEmpty { message += " as \(facts.user)" }
                if facts.dockerAvailable { message += ". Docker found." }
                testState = .success(message)
            } catch {
                if !Task.isCancelled { testState = .failure(error.localizedDescription) }
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
