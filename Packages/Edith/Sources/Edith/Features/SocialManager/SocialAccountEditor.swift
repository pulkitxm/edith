import EdithKit
import SwiftUI

struct SocialAccountEditor: View {
    let model: SocialManagerModel
    let profile: SocialProfile
    let account: SocialAccount?
    @Environment(\.dismiss) private var dismiss
    @State private var platformID: UUID
    @State private var name: String
    @State private var badge: String
    @State private var error: String?
    @State private var pictureURL: URL?
    @State private var removingPicture = false
    @State private var website: String
    @State private var shareProfileSession: Bool
    @State private var username: String

    init(model: SocialManagerModel, profile: SocialProfile, account: SocialAccount? = nil) {
        self.model = model
        self.profile = profile
        self.account = account
        _platformID = State(
            initialValue: account?.platformID ?? model.catalog.platforms.first?.id ?? UUID())
        _name = State(initialValue: account?.name ?? model.catalog.platforms.first?.name ?? "")
        _badge = State(initialValue: account?.badge ?? "")
        _username = State(initialValue: account?.username ?? "")
        let platform = model.catalog.platforms.first {
            $0.id == (account?.platformID ?? model.catalog.platforms.first?.id)
        }
        _website = State(
            initialValue: (account?.website ?? platform?.website)?.absoluteString ?? "")
        _shareProfileSession = State(
            initialValue: account.map { $0.browserSessionID != nil }
                ?? (platform?.isGoogleService == true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            Text(account == nil ? "Add social account" : "Edit account").font(.edithText(.title2))
            Text(profile.name).font(.edithText(.headline)).foregroundStyle(.secondary)
            SocialPicturePicker(
                savedImage: account.flatMap { model.avatars[$0.id] },
                pictureURL: $pictureURL, removingPicture: $removingPicture
            ) { error = $0.localizedDescription }
            Form {
                Picker("Platform", selection: $platformID) {
                    ForEach(model.catalog.platforms) { Text($0.name).tag($0.id) }
                }.disabled(account != nil)
                    .onChange(of: platformID) { old, new in
                        if name == model.catalog.platforms.first(where: { $0.id == old })?.name {
                            name =
                                model.catalog.platforms.first(where: { $0.id == new })?.name ?? ""
                        }
                        if let platform = model.catalog.platforms.first(where: { $0.id == new }) {
                            website = platform.website.absoluteString
                            shareProfileSession = platform.isGoogleService
                        }
                    }
                TextField("Account label", text: $name, prompt: Text("Username or channel name"))
                TextField("Username", text: $username, prompt: Text("@username"))
                TextField("Badge", text: $badge, prompt: Text("Optional emoji or initials"))
                TextField("Account URL", text: $website, prompt: Text("https://studio.youtube.com"))
                if account?.id != profile.id {
                    Toggle("Use this profile's Google session", isOn: $shareProfileSession)
                }
            }
            Text(
                shareProfileSession
                    ? "Shares cookies with this profile's Gmail and linked accounts. Your separate session stays saved if you switch back. Other profiles keep their own logins."
                    : "This account keeps its own cookies and website storage. Its login and account URL are saved across app restarts."
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
                            id: account?.id, profileID: profile.id, platformID: platformID,
                            name: name, badge: badge, pictureURL: pictureURL,
                            removePicture: removingPicture, website: website,
                            shareProfileSession: shareProfileSession, username: username)
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
    let profile: SocialProfile
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var website = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            Text("Add a website").font(.edithText(.title2))
            Text(profile.name).font(.edithText(.headline)).foregroundStyle(.secondary)
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
                Button("Add and open") {
                    do {
                        let account = try model.addWebsite(
                            profileID: profile.id, name: name, website: website)
                        model.open(account)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || website.isEmpty
                        || model.busy)
            }
        }
        .font(.edithText(.body))
        .padding(UIScale.pt(24)).frame(width: UIScale.pt(420))
    }
}
