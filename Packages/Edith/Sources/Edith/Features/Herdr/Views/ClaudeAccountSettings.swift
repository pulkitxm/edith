import EdithKit
import SwiftUI

struct ClaudeAccountSettings: View {
    let accounts: ClaudeAccountsModel
    var machine: Machine? = nil
    var accountAdded: (ClaudeAccount) -> Void = { _ in }
    @State private var draft: ClaudeAccount?

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
                            if let account = await accounts.importCurrentCLIAccount(on: machine) {
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
                                "Generate a token with claude setup-token. Tokens without profile access can launch sessions but cannot show subscription limits."
                            )
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(
                            "Keeps a separate subscription login for this account on each machine. Sign in once per machine. Skills, plugins and settings are shared."
                        )
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let draft, draft.authentication == .oauthToken,
                        accounts.account(draft.id) != nil
                    {
                        Text("Subscription limits").font(.edithText(.caption))
                        Button(
                            draft.limitsProfileID == nil
                                ? "Connect subscription for limits"
                                : "Reconnect subscription for limits"
                        ) {
                            Task {
                                if let linked = await accounts.connectLimitsLogin(draft) {
                                    self.draft = linked
                                }
                            }
                        }
                        Text(
                            "Sign in to this same account in the limits terminal on this Mac. This login is used only to read limits and renews automatically. Your launch token stays unchanged."
                        )
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        if draft.limitsProfileID != nil {
                            Button("Disconnect limits login") {
                                self.draft?.limitsProfileID = nil
                                saveDraft()
                            }
                        }
                    }
                    HStack {
                        Button("Save account") { saveDraft() }
                            .buttonStyle(.edith(.toolbar))
                        if let draft, accounts.state.accounts.contains(where: { $0.id == draft.id })
                        {
                            Button("Remove account", role: .destructive) { removeDraft() }
                        }
                        Spacer()
                    }
                }
            }
            .disabled(!accounts.ready || accounts.saving)
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
                if value != draft?.authentication {
                    draft?.loginData = nil
                    draft?.limitsProfileID = nil
                }
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
        if let previous = accounts.account(draft.id), previous.credential != draft.credential {
            draft.limitsProfileID = nil
        }
        self.draft = draft
        var next = accounts.state
        if next.accounts.isEmpty { next.defaultID = draft.id }
        if let index = next.accounts.firstIndex(where: { $0.id == draft.id }) {
            next.accounts[index] = draft
        } else {
            next.accounts.append(draft)
        }
        let added = !accounts.state.accounts.contains { $0.id == draft.id }
        Task {
            await accounts.save(next)
            if added, accounts.error == nil { accountAdded(draft) }
        }
    }

    private func removeDraft() {
        guard let draft else { return }
        var next = accounts.state
        next.accounts.removeAll { $0.id == draft.id }
        if next.defaultID == draft.id { next.defaultID = nil }
        Task {
            await accounts.save(next)
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
    @Binding var selection: String
    @State private var editing = false

    var body: some View {
        HStack {
            Picker(
                "Claude account",
                selection: Binding(
                    get: { accounts.launchSelection(selection) },
                    set: { value in
                        selection = value
                        Task { await accounts.rememberLaunchSelection(value) }
                    })
            ) {
                if accounts.state.accounts.isEmpty {
                    Text("Existing CLI login").tag("cli")
                }
                ForEach(accounts.state.accounts) { account in
                    Text(account.name).tag(account.id.uuidString)
                }
            }
            Button("Manage accounts") { editing = true }
        }
        .font(.edithText(.caption))
        .pageTask {
            await accounts.read()
            selection = accounts.launchSelection(selection)
        }
        .edithSheet(isPresented: $editing) {
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    ClaudeAccountSettings(
                        accounts: accounts, machine: machine,
                        accountAdded: { account in
                            selection = account.id.uuidString
                            Task { await accounts.rememberLaunchSelection(account.id.uuidString) }
                        })
                    Divider()
                    ClaudeSharedLaunchSettings()
                    Button("Done") { editing = false }
                }
                .padding(UIScale.pt(18))
            }
            .frame(width: PresentationMetrics.width(540), height: PresentationMetrics.width(640))
        }
    }
}
