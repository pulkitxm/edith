import EdithKit
import SwiftUI

struct SocialAccountEditor: View {
    let model: SocialManagerModel
    let account: SocialAccount?
    @Environment(\.dismiss) private var dismiss
    @State private var platformID: UUID
    @State private var name: String
    @State private var badge: String
    @State private var error: String?

    init(model: SocialManagerModel, account: SocialAccount? = nil, platformID: UUID? = nil) {
        self.model = model
        self.account = account
        _platformID = State(initialValue: platformID ?? model.catalog.platforms.first?.id ?? UUID())
        _name = State(initialValue: account?.name ?? "")
        _badge = State(initialValue: account?.badge ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            Text(account == nil ? "Add social account" : "Edit account").font(.edithText(.title2))
            Form {
                Picker("Platform", selection: $platformID) {
                    ForEach(model.catalog.platforms) { Text($0.name).tag($0.id) }
                }.disabled(account != nil)
                TextField("Account name", text: $name, prompt: Text("Personal, Studio, Client…"))
                TextField("Badge", text: $badge, prompt: Text("Optional emoji or initials"))
            }
            Text(
                "Sign in directly on the website. Each account keeps its own cookies and website storage, including across app restarts. Passwords are entered only on the website."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
            if let error { Text(error).font(.edithText(.caption)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(account == nil ? "Add and open" : "Save") {
                    do {
                        let saved = try model.saveAccount(
                            id: account?.id, platformID: platformID, name: name, badge: badge)
                        if account == nil { model.open(saved) }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            }
        }
        .font(.edithText(.body))
        .padding(UIScale.pt(24)).frame(width: UIScale.pt(420))
    }
}

struct SocialPlatformEditor: View {
    let model: SocialManagerModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var website = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            Text("Add a website").font(.edithText(.title2))
            Form {
                TextField("Platform name", text: $name, prompt: Text("LinkedIn"))
                TextField("Website URL", text: $website, prompt: Text("https://www.linkedin.com"))
            }
            Text("Any HTTPS website can have multiple separate account sessions.")
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            if let error { Text(error).font(.edithText(.caption)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add website") {
                    do {
                        try model.addPlatform(name: name, website: website)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || website.isEmpty)
            }
        }
        .font(.edithText(.body))
        .padding(UIScale.pt(24)).frame(width: UIScale.pt(420))
    }
}
