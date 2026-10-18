import EdithKit
import SwiftUI

struct SocialProfileEditor: View {
    let model: SocialManagerModel
    let profile: SocialProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var badge: String
    @State private var email: String
    @State private var error: String?

    init(model: SocialManagerModel, profile: SocialProfile? = nil) {
        self.model = model
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _badge = State(initialValue: profile?.badge ?? "")
        _email = State(initialValue: profile?.email ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            Text(profile == nil ? "Add profile" : "Edit profile").font(.edithText(.title2))
            Form {
                TextField("Profile name", text: $name, prompt: Text("Personal, Studio, Client…"))
                TextField("Badge", text: $badge, prompt: Text("Optional emoji or initials"))
                TextField("Profile email", text: $email, prompt: Text("name@gmail.com"))
            }
            Text(
                "Keep this profile's Instagram, YouTube, X, LinkedIn and other accounts together. Add only the platforms you use, with a separate login for every connected account."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
            if let error { Text(error).font(.edithText(.caption)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(profile == nil ? "Create profile" : "Save") {
                    do {
                        try model.saveProfile(
                            id: profile?.id, name: name, badge: badge, email: email)
                        if profile == nil { model.showingAccounts = true }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            }
        }
        .font(.edithText(.body)).padding(UIScale.pt(24)).frame(width: UIScale.pt(420))
    }
}
