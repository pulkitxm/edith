import EdithExtensionAccounts
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct ClaudeAccountSettings: View {
    let accounts: ClaudeAccountsModel
    var machine: Machine? = nil
    var machineID: String? = nil
    var accountAdded: (ClaudeAccount) -> Void = { _ in }
    @State private var draft: ClaudeAccount?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Group {
                Text("Claude accounts").font(.edithText(.headline))
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text("Account").font(.edithText(.caption))
                    Picker(
                        "Account",
                        selection: Binding(
                            get: { draft?.id },
                            set: { draft = accounts.account($0) })
                    ) {
                        if accounts.state.accounts.isEmpty {
                            Text("Choose an account").tag(UUID?.none)
                        }
                        ForEach(accounts.state.accounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                        if let draft,
                            !accounts.state.accounts.contains(where: { $0.id == draft.id })
                        {
                            Text("New account").tag(Optional(draft.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Add account") { draft = ClaudeAccount(name: "New account") }
                    Button("Use current CLI account") {
                        Task {
                            if let account = await accounts.importCurrentCLIAccount(
                                on: machine, machineID: machineID),
                                await accounts.rememberLaunchSelection(account.id.uuidString)
                            {
                                draft = account
                                accountAdded(account)
                            }
                        }
                    }
                    .help(
                        "Copy the current CLI credentials into a named account and use it for new sessions."
                    )
                }
                if draft != nil {
                    Text("Account name").font(.edithText(.caption))
                    TextField("Account name", text: binding(\.name))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Account name")
                    Text("Authentication").font(.edithText(.caption))
                    Picker("Authentication", selection: authenticationBinding) {
                        ForEach(ClaudeAccount.Authentication.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if draft?.authentication == .browserLogin, draft?.loginData != nil {
                        Text("Full OAuth token").font(.edithText(.caption))
                        Text(draft?.credential ?? "")
                            .font(.system(size: UIScale.pt(11), design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if draft?.authentication != .browserLogin {
                        Text(draft?.authentication == .apiKey ? "Full API key" : "Full OAuth token")
                            .font(.edithText(.caption))
                        ShellInputEditor(text: binding(\.credential), label: "Full credential")
                            .frame(height: UIScale.pt(64))
                            .accessibilityLabel("Full credential")
                        if draft?.authentication == .oauthToken {
                            Text(
                                "Generate a token with claude setup-token. Connect a subscription login to show limits when this token has no profile access."
                            )
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(
                            "The first launch opens Claude's login flow. Each account keeps its own login and settings."
                        )
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let draft, draft.authentication == .oauthToken,
                        let saved = accounts.account(draft.id), !saved.isLoggedOut,
                        saved.authentication == .oauthToken
                    {
                        Button(
                            saved.limitsProfileID == nil
                                ? "Connect subscription limits" : "Reconnect subscription limits"
                        ) {
                            accounts.subscriptionLogin.start(
                                accountID: saved.id, accounts: accounts,
                                defaults: SharedDefaults.store)
                        }
                        .help(
                            "Sign in for subscription limits while keeping this account's launch token."
                        )
                    }
                    HStack {
                        Button("Save account") { saveDraft() }
                            .buttonStyle(.edith(.toolbar))
                        if let draft, accounts.state.accounts.contains(where: { $0.id == draft.id })
                        {
                            Button("Sign out account") {
                                Task {
                                    await accounts.logout(draft.id)
                                    self.draft = accounts.account(draft.id)
                                }
                            }
                            Button("Remove account", role: .destructive) { removeDraft() }
                        }
                        Spacer()
                    }
                }
            }
            .disabled(!accounts.ready || accounts.saving || accounts.subscriptionLogin.running)
            if accounts.subscriptionLogin.running {
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    Text("Complete subscription sign-in in this terminal.")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                    TerminalPane(
                        holder: accounts.subscriptionLogin.holder,
                        palette: .edith(dark: scheme == .dark)
                    )
                    .frame(height: UIScale.pt(200))
                    Button("Cancel sign-in") { accounts.subscriptionLogin.cancel() }
                }
            }
            if let error = accounts.subscriptionLogin.error {
                Text(error).font(.edithText(.caption)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if accounts.subscriptionLogin.state?.phase == .connected {
                Text("Subscription limits connected.")
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            if let error = accounts.error {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Button("Reload") { Task { await accounts.read() } }
                }.font(.edithText(.caption))
            }
        }
        .onAppear {
            selectAccountIfNeeded()
        }
        .onDisappear { accounts.subscriptionLogin.cancel() }
        .pageTask {
            await accounts.read()
            selectAccountIfNeeded()
        }
        .onChange(of: accounts.state.accounts.map(\.id)) { _, _ in
            selectAccountIfNeeded()
        }
    }

    private func selectAccountIfNeeded() {
        guard draft == nil else { return }
        draft = accounts.account(accounts.state.defaultID) ?? accounts.state.accounts.first
    }

    private var authenticationBinding: Binding<ClaudeAccount.Authentication> {
        Binding(
            get: { draft?.authentication ?? .oauthToken },
            set: { value in
                if value != draft?.authentication { draft?.loginData = nil }
                draft?.authentication = value
            })
    }

    private func binding<Value>(_ path: WritableKeyPath<ClaudeAccount, Value>) -> Binding<Value> {
        let initial = draft![keyPath: path]
        return Binding(
            get: { draft?[keyPath: path] ?? initial }, set: { draft?[keyPath: path] = $0 })
    }

    private func saveDraft() {
        guard var draft else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.credential =
            draft.authentication == .browserLogin && draft.loginData == nil
            ? "" : draft.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.credential.isEmpty { draft.isLoggedOut = false }
        self.draft = draft
        var next = accounts.state
        if next.accounts.isEmpty { next.defaultID = draft.id }
        if let index = next.accounts.firstIndex(where: { $0.id == draft.id }) {
            draft.limitsProfileID = next.accounts[index].limitsProfileID
            next.accounts[index] = draft
        } else {
            next.accounts.append(draft)
        }
        let added = !accounts.state.accounts.contains { $0.id == draft.id }
        Task {
            await accounts.save(next)
            if added, accounts.error == nil,
                await accounts.rememberLaunchSelection(draft.id.uuidString)
            {
                accountAdded(draft)
            }
        }
    }

    private func removeDraft() {
        guard let draft else { return }
        Task {
            await accounts.forget(draft.id)
            if accounts.error == nil {
                self.draft = nil
                selectAccountIfNeeded()
            }
        }
    }
}

struct ClaudeAccountLaunchPicker: View {
    let accounts: ClaudeAccountsModel
    var machine: Machine? = nil
    var machineID: String? = nil
    @Binding var selection: String
    @State private var editing = false
    @State private var selectionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            HStack {
                Picker(
                    "Claude account",
                    selection: Binding(
                        get: { accounts.launchSelection(selection) }, set: choose)
                ) {
                    Text("Existing CLI login").tag("cli")
                    ForEach(accounts.launchAccounts) { account in
                        Text("\(account.name) (\(account.authentication.title))").tag(
                            account.id.uuidString)
                    }
                }
                .disabled(!accounts.ready || accounts.saving)
                Button("Manage accounts") { editing = true }
            }
            if let selectionError {
                Text(selectionError).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.edithText(.caption))
        .pageTask {
            await accounts.read()
            selection = accounts.launchSelection(selection)
        }
        .onChange(of: accounts.state.accounts.map(\.id)) { _, _ in
            selection = accounts.launchSelection(selection)
        }
        .edithSheet(isPresented: $editing, dismissible: !accounts.subscriptionLogin.running) {
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    ClaudeAccountSettings(
                        accounts: accounts, machine: machine, machineID: machineID,
                        accountAdded: {
                            selection = $0.id.uuidString; selectionError = nil
                        })
                    Divider()
                    ClaudeSharedLaunchSettings(accounts: accounts)
                        .disabled(accounts.subscriptionLogin.running)
                    Button("Done") { editing = false }
                        .disabled(accounts.subscriptionLogin.running)
                }
                .padding(UIScale.pt(18))
            }
            .frame(width: PresentationMetrics.width(540), height: PresentationMetrics.width(640))
        }
    }

    private func choose(_ value: String) {
        selection = value
        selectionError = nil
        Task {
            if await accounts.rememberLaunchSelection(value) {
                if selectionError != nil { selection = accounts.launchSelection("default") }
                return
            }
            guard selection == value else { return }
            selectionError =
                accounts.error ?? "This account could not be selected. Reload and try again."
            selection = accounts.launchSelection("default")
        }
    }

}
