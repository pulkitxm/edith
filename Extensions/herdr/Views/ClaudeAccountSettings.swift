import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct ClaudeAccountSettings: View {
    let accounts: ClaudeAccountsModel
    @State private var draft: ClaudeAccount?
    @State private var defaultID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Text("Claude accounts").font(.edithText(.headline))
            HStack {
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
                    if let draft, !accounts.state.accounts.contains(where: { $0.id == draft.id }) {
                        Text("New account").tag(Optional(draft.id))
                    }
                }
                Button("Add account") { draft = ClaudeAccount(name: "New account") }
            }
            if draft != nil {
                TextField("Account name", text: binding(\.name))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Account name")
                Picker("Authentication", selection: binding(\.authentication)) {
                    ForEach(ClaudeAccount.Authentication.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                if draft?.authentication != .browserLogin {
                    Text(draft?.authentication == .apiKey ? "Full API key" : "Full OAuth token")
                        .font(.edithText(.caption))
                    TextEditor(text: binding(\.credential))
                        .font(.system(size: UIScale.pt(11), design: .monospaced))
                        .frame(height: UIScale.pt(64))
                        .accessibilityLabel("Full credential")
                    if draft?.authentication == .oauthToken {
                        Text("Generate a token for the desired account with claude setup-token.")
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
                    if let draft, accounts.state.accounts.contains(where: { $0.id == draft.id }) {
                        Button("Remove account", role: .destructive) { removeDraft() }
                    }
                    Spacer()
                }
            }
            Picker("Default for new Claude sessions", selection: $defaultID) {
                Text("Existing CLI login").tag(UUID?.none)
                ForEach(accounts.state.accounts) { account in
                    Text(account.name).tag(Optional(account.id))
                }
            }
            .onChange(of: defaultID) { _, value in
                guard accounts.ready, value != accounts.state.defaultID else { return }
                var next = accounts.state
                next.defaultID = value
                HerdrWorkOwnership.start { await accounts.save(next) }
            }
            if let error = accounts.error {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Button("Reload") { HerdrWorkOwnership.start { await accounts.read() } }
                }.font(.edithText(.caption))
            }
        }
        .disabled(!accounts.ready || accounts.saving)
        .pageTask {
            await accounts.read()
            defaultID = accounts.state.defaultID
            if draft == nil { draft = accounts.state.accounts.first }
        }
        .onChange(of: accounts.state.defaultID) { _, value in defaultID = value }
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
            draft.authentication == .browserLogin
            ? "" : draft.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        self.draft = draft
        var next = accounts.state
        if let index = next.accounts.firstIndex(where: { $0.id == draft.id }) {
            next.accounts[index] = draft
        } else {
            next.accounts.append(draft)
        }
        HerdrWorkOwnership.start { await accounts.save(next) }
    }

    private func removeDraft() {
        guard let draft else { return }
        var next = accounts.state
        next.accounts.removeAll { $0.id == draft.id }
        if next.defaultID == draft.id { next.defaultID = nil }
        HerdrWorkOwnership.start {
            await accounts.save(next)
            if accounts.error == nil { self.draft = nil }
        }
    }
}

struct ClaudeAccountLaunchPicker: View {
    let accounts: ClaudeAccountsModel
    @Binding var selection: String
    @State private var editing = false

    var body: some View {
        HStack {
            Picker("Claude account", selection: $selection) {
                Text("Launch default").tag("default")
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
                ClaudeAccountSettings(accounts: accounts)
                Button("Done") { editing = false }
            }
            .padding(UIScale.pt(18))
            .frame(width: PresentationMetrics.width(540))
        }
    }
}
