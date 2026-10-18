import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct SocialAccountEditor: View {
    let model: SocialManagerModel
    let profile: SocialProfile
    let account: SocialAccount?
    @Environment(\.dismiss) private var dismiss
    @State private var platformID: UUID
    @State private var name: String
    @State private var badge: String
    @State private var error: String?
    @State private var choosingPicture = false
    @State private var pictureURL: URL?
    @State private var picture: NSImage?
    @State private var removingPicture = false

    init(model: SocialManagerModel, profile: SocialProfile, account: SocialAccount? = nil) {
        self.model = model
        self.profile = profile
        self.account = account
        _platformID = State(
            initialValue: account?.platformID ?? model.catalog.platforms.first?.id ?? UUID())
        _name = State(initialValue: account?.name ?? model.catalog.platforms.first?.name ?? "")
        _badge = State(initialValue: account?.badge ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            Text(account == nil ? "Add social account" : "Edit account").font(.edithText(.title2))
            Text(profile.name).font(.edithText(.headline)).foregroundStyle(.secondary)
            HStack {
                if let image = picture
                    ?? (removingPicture ? nil : account.flatMap { model.avatars[$0.id] })
                {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: UIScale.pt(52), height: UIScale.pt(52)).clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle").font(.edithText(.largeTitle))
                }
                Button("Choose picture…") { choosingPicture = true }
                if picture != nil || (!removingPicture && account?.avatarFilename != nil) {
                    Button("Remove picture") {
                        pictureURL = nil; picture = nil; removingPicture = true
                    }
                }
            }
            Form {
                Picker("Platform", selection: $platformID) {
                    ForEach(model.catalog.platforms) { Text($0.name).tag($0.id) }
                }.disabled(account != nil)
                    .onChange(of: platformID) { old, new in
                        if name == model.catalog.platforms.first(where: { $0.id == old })?.name {
                            name =
                                model.catalog.platforms.first(where: { $0.id == new })?.name ?? ""
                        }
                    }
                TextField("Account label", text: $name, prompt: Text("Username or channel name"))
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
                            id: account?.id, profileID: profile.id, platformID: platformID,
                            name: name, badge: badge, pictureURL: pictureURL,
                            removePicture: removingPicture)
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
        .fileImporter(isPresented: $choosingPicture, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let data = try SocialAvatarFiles.thumbnail(url)
                picture = NSImage(data: data)
                pictureURL = url
                removingPicture = false
            } catch { self.error = error.localizedDescription }
        }
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
