import EdithKit
import SwiftUI

struct ClaudeAccountSettings: View {
    let accounts: ClaudeAccountsModel
    var machine: Machine? = nil
    var accountAdded: (ClaudeAccount) -> Void = { _ in }
    @State private var draft: ClaudeAccount?
    @State private var defaultID: UUID?

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
                        Text("Choose an account").tag(UUID?.none)
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
                                defaultID = account.id
                                accountAdded(account)
                            }
                        }
                    }
                    .help(
                        "Copy the current CLI credentials into a named account and use it for new sessions."
                    )
                }
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text("Default for new Claude sessions").font(.edithText(.caption))
                    Picker("Default for new Claude sessions", selection: $defaultID) {
                        Text("Existing CLI login").tag(UUID?.none)
                        ForEach(accounts.state.accounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: defaultID) { _, value in
                        guard accounts.ready, value != accounts.state.defaultID else { return }
                        var next = accounts.state
                        next.defaultID = value
                        Task {
                            await accounts.save(next)
                            if accounts.error != nil { defaultID = accounts.state.defaultID }
                        }
                    }
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
                        TextEditor(text: binding(\.credential))
                            .font(.system(size: UIScale.pt(11), design: .monospaced))
                            .frame(height: UIScale.pt(64))
                            .accessibilityLabel("Full credential")
                        if draft?.authentication == .oauthToken {
                            Text(
                                "Generate a token with claude setup-token. Tokens without profile access can launch sessions but cannot show subscription limits."
                            )
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(
                            "The first launch opens Claude's login flow. Each account keeps its own login and settings."
                        )
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
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
        .pageTask {
            await accounts.read()
            defaultID = accounts.state.defaultID
            selectAccountIfNeeded()
        }
        .onChange(of: accounts.state.accounts.map(\.id)) { _, _ in
            selectAccountIfNeeded()
        }
        .onChange(of: accounts.state.defaultID) { _, value in defaultID = value }
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
            Picker("Claude account", selection: $selection) {
                Text(
                    "Launch default: \(accounts.account(accounts.state.defaultID)?.name ?? "Existing CLI login")"
                )
                .tag("default")
                Text("Existing CLI login").tag("cli")
                ForEach(accounts.state.accounts) { account in
                    Text("\(account.name) (\(account.authentication.title))").tag(
                        account.id.uuidString)
                }
            }
            Button("Manage accounts") { editing = true }
        }
        .font(.edithText(.caption))
        .pageTask { await accounts.read() }
        .edithSheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                ClaudeAccountSettings(
                    accounts: accounts, machine: machine,
                    accountAdded: { selection = $0.id.uuidString })
                Button("Done") { editing = false }
            }
            .padding(UIScale.pt(18))
            .frame(width: PresentationMetrics.width(540))
        }
    }
}
