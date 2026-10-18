import EdithKit
import SwiftUI

struct SocialManagerPage: View {
    @Environment(\.windowSessionOwner) private var owner
    @StateObject private var fallback = WindowSessionOwner()
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @Environment(\.windowRouter) private var router
    @State private var commandOwner = UUID()
    @State private var addingAccount = false
    @State private var addingPlatform = false
    @State private var addingProfile = false
    @State private var editingProfile: SocialProfile?
    @State private var removingProfile: SocialProfile?
    private let providedModel: SocialManagerModel?

    init(model: SocialManagerModel? = nil) { providedModel = model }

    private var model: SocialManagerModel {
        providedModel ?? owner?.socialManager ?? fallback.socialManager
    }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        @Bindable var model = model
        PageWorkspace {
            PageHeader("Social Manager") {
                if let account = model.focusedAccount, let profile = model.profile(for: account) {
                    SocialEmailMenu(model: model, profile: profile)
                }
                if !model.showingAccounts, let tab = model.currentTab {
                    layoutMenu(tab)
                }
                Button {
                    if model.selectedProfile == nil {
                        addingProfile = true
                    } else {
                        addingAccount = true
                    }
                } label: {
                    Label(
                        model.selectedProfile == nil ? "Add profile" : "Add account",
                        systemImage: "plus")
                }
                .disabled(!model.load.hasContent || model.busy)
            } accessory: {
                Text("Your profiles. Every platform. One workspace.")
                    .font(.edithText(.subheadline)).foregroundStyle(.secondary)
            }
            tabs
            if let message = model.message {
                HStack {
                    Text(message).font(.edithText(.caption)).textSelection(.enabled)
                    Spacer()
                    Button {
                        model.message = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Dismiss message")
                }
                .padding(UIScale.pt(10)).pageGutter(compact)
            }
            Divider()
        } content: {
            if model.showingAccounts || model.currentTab == nil {
                library
            } else {
                SocialBrowserCanvas(model: model)
            }
        }
        .pageTask { model.start() }
        .onAppear {
            router?.registerWorkspaceCommands(owner: commandOwner) { [weak model] command in
                guard !addingAccount, !addingPlatform, !addingProfile,
                    editingProfile == nil, removingProfile == nil,
                    model?.editingAccount == nil, model?.clearingAccount == nil,
                    model?.removingAccount == nil
                else { return false }
                return model?.perform(command) ?? false
            }
        }
        .onDisappear { router?.unregisterWorkspaceCommands(owner: commandOwner) }
        .edithSheet(isPresented: $addingAccount, dismissible: false) {
            if let profile = model.selectedProfile {
                SocialAccountEditor(model: model, profile: profile)
            }
        }
        .edithSheet(isPresented: $addingProfile, dismissible: false) {
            SocialProfileEditor(model: model)
        }
        .edithSheet(item: $editingProfile, dismissible: false) { profile in
            SocialProfileEditor(model: model, profile: profile)
        }
        .edithSheet(isPresented: $addingPlatform, dismissible: false) {
            if let profile = model.selectedProfile {
                SocialPlatformEditor(model: model, profile: profile)
            }
        }
        .edithSheet(item: $model.editingAccount, dismissible: false) { account in
            if let profile = model.profile(for: account) {
                SocialAccountEditor(model: model, profile: profile, account: account)
            }
        }
        .confirmationDialog(
            "Remove this profile?",
            isPresented: Binding(
                get: { removingProfile != nil }, set: { if !$0 { removingProfile = nil } }),
            titleVisibility: .visible, presenting: removingProfile
        ) { profile in
            Button("Remove profile", role: .destructive) {
                Task { await model.removeProfile(profile) }
            }
        } message: { profile in
            Text(
                "Remove \(profile.name) and its connected accounts from Edith, including their local login sessions. Your accounts on the websites and other profiles are kept."
            )
        }
        .confirmationDialog(
            "Clear this account's session?",
            isPresented: Binding(
                get: { model.clearingAccount != nil },
                set: { if !$0 { model.clearingAccount = nil } }),
            titleVisibility: .visible, presenting: model.clearingAccount
        ) { account in
            Button("Clear session", role: .destructive) {
                Task { await model.clearSession(account, removingAccount: false) }
            }
        } message: { account in
            Text(
                "\(account.name) will close and its cookies and website storage will be deleted. Your other accounts keep their sessions."
            )
        }
        .confirmationDialog(
            "Remove this account?",
            isPresented: Binding(
                get: { model.removingAccount != nil },
                set: { if !$0 { model.removingAccount = nil } }),
            titleVisibility: .visible, presenting: model.removingAccount
        ) { account in
            Button("Remove account", role: .destructive) {
                Task { await model.clearSession(account, removingAccount: true) }
            }
        } message: { account in
            Text(
                "Remove \(account.name) from Edith and delete its local browser session. The account on the website is kept."
            )
        }
    }

    private var tabs: some View {
        PageTabStrip(
            selection: model.showingAccounts
                ? "accounts" : model.selectedTabID?.uuidString ?? "accounts"
        ) {
            HStack(spacing: UIScale.pt(6)) {
                tabChip("Profiles", symbol: "person.2", selected: model.showingAccounts) {
                    model.showingAccounts = true
                    model.profileID = nil
                }.id("accounts")
                    .contextMenu {
                        Button("Add profile") { addingProfile = true }
                        Button("Reopen closed tab") { model.reopenClosedTab() }
                            .disabled(model.recentlyClosed.isEmpty)
                    }
                ForEach(model.tabs) { tab in
                    HStack(spacing: UIScale.pt(4)) {
                        tabChip(
                            model.title(tab),
                            symbol: tab.layout.paneCount > 1 ? "rectangle.split.2x1" : "globe",
                            selected: !model.showingAccounts && model.selectedTabID == tab.id
                        ) { model.select(tab) }
                        Button {
                            model.closeTab(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.edith(.borderless))
                        .accessibilityLabel("Close \(model.title(tab))")
                        .help("Close tab. Login sessions are kept.")
                    }
                    .id(tab.id.uuidString)
                    .contextMenu { SocialTabActions(model: model, tab: tab) }
                    .draggable("social-tab:\(tab.id)")
                    .dropDestination(for: String.self) { values, _ in
                        guard let value = values.first, value.hasPrefix("social-tab:"),
                            let id = UUID(uuidString: String(value.dropFirst(11)))
                        else { return false }
                        model.reorderTab(id, before: tab.id)
                        return true
                    }
                }
            }
            .padding(.vertical, UIScale.pt(8)).pageGutter(compact)
        }
    }

    private func tabChip(
        _ title: String, symbol: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.edithText(.subheadline)).lineLimit(1)
                .padding(.horizontal, UIScale.pt(12)).padding(.vertical, UIScale.pt(7))
                .background(selected ? DashSkin.accent(dark).opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var library: some View {
        PageScaffold {
            EmptyView()
        } content: {
            PageLoading(
                state: model.load.state, title: "Social profiles",
                message: model.load.errorMessage ?? "Loading your profiles and connected accounts.",
                layout: .cards, retry: { model.start() }
            ) {
                VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                    if let profile = model.selectedProfile {
                        Button("All profiles", systemImage: "chevron.left") {
                            model.profileID = nil
                        }
                        accounts(for: profile)
                    } else {
                        PageSectionHeader(
                            "Profiles",
                            subtitle:
                                "Keep the social accounts for each person, brand or client together."
                        )
                        if model.catalog.profiles.isEmpty {
                            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                                Text("Create your first profile").font(.edithText(.headline))
                                Text(
                                    "Add Personal, Studio or a client, then choose the Instagram, YouTube, X, LinkedIn and other accounts that belong to it."
                                )
                                .font(.edithText(.body)).foregroundStyle(.secondary)
                                Button("Add profile", systemImage: "plus") { addingProfile = true }
                            }.padding(UIScale.pt(20))
                        }
                        LazyVGrid(
                            columns: PageMetrics.cardColumns(compact, minimum: 250, spacing: 12),
                            spacing: UIScale.pt(12)
                        ) {
                            ForEach(model.catalog.profiles) { profile in profileCard(profile) }
                        }
                    }
                    Label(
                        "Sign in on each website once. Cookies and website storage stay in that account's own persistent browser session on this Mac.",
                        systemImage: "lock.shield"
                    )
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func profileCard(_ profile: SocialProfile) -> some View {
        let accounts = model.accounts(in: profile)
        let platforms = model.catalog.platforms.filter { platform in
            accounts.contains { $0.platformID == platform.id }
        }
        return Button {
            model.profileID = profile.id
        } label: {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                HStack {
                    SocialAvatar(
                        image: model.profileAvatars[profile.id], initials: profile.initials,
                        name: profile.name)
                    Spacer()
                    Text("\(accounts.count) \(accounts.count == 1 ? "account" : "accounts")")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                Text(profile.name).font(.edithText(.headline)).foregroundStyle(.primary)
                if let email = profile.email {
                    Text(email).font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(
                    platforms.isEmpty
                        ? "Add your social accounts"
                        : platforms.map(\.name).joined(separator: " · ")
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(UIScale.pt(18)).frame(maxWidth: .infinity, alignment: .leading)
            .background(DashSkin.paper2(dark))
            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(12)))
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                    DashSkin.line(dark)))
        }
        .buttonStyle(.edith(.borderless))
        .contextMenu { profileActions(profile) }
        .draggable("social-profile:\(profile.id)")
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, value.hasPrefix("social-profile:"),
                let id = UUID(uuidString: String(value.dropFirst(15)))
            else { return false }
            model.reorderProfile(id, before: profile.id)
            return true
        }
    }

    @ViewBuilder private func profileActions(_ profile: SocialProfile) -> some View {
        Button("Open profile") {
            model.profileID = profile.id; model.showingAccounts = true
        }
        Button("Open all in tabs") { model.openAll(profile, sideBySide: false) }
            .disabled(model.accounts(in: profile).isEmpty)
        Button("Open all side by side") { model.openAll(profile, sideBySide: true) }
            .disabled(model.accounts(in: profile).isEmpty)
        SocialEmailMenu(model: model, profile: profile)
        Divider()
        Button("Edit profile…") { editingProfile = profile }
        SocialPictureActions(name: profile.name, hasPicture: profile.avatarFilename != nil) { url in
            do { try model.importAvatar(profile, from: url) } catch {
                model.message = error.localizedDescription
            }
        } remove: {
            model.removeAvatar(profile)
        }
        Button("Remove profile…", role: .destructive) { removingProfile = profile }
    }

    private func accounts(for profile: SocialProfile) -> some View {
        let accounts = model.accounts(in: profile)
        return VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack {
                SocialAvatar(
                    image: model.profileAvatars[profile.id], initials: profile.initials,
                    name: profile.name, size: 52)
                if let email = profile.email {
                    Text(email).font(.edithText(.subheadline)).foregroundStyle(.secondary)
                }
            }
            PageSectionHeader(profile.name, subtitle: "Connected accounts") {
                SocialEmailMenu(model: model, profile: profile)
                Menu {
                    profileActions(profile)
                    Button("Add custom website") { addingPlatform = true }
                } label: {
                    Label("Manage profile", systemImage: "ellipsis")
                }
                Button("Add account", systemImage: "plus") { addingAccount = true }
            }.disabled(model.busy)
            if accounts.isEmpty {
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    Text("Add accounts to \(profile.name)").font(.edithText(.headline))
                    Text(
                        "Choose Instagram, YouTube, X, LinkedIn or another website, then sign in. Only the accounts you add appear in this profile."
                    )
                    .font(.edithText(.body)).foregroundStyle(.secondary)
                    Button("Add account") { addingAccount = true }.disabled(model.busy)
                }
                .padding(UIScale.pt(20))
            } else {
                LazyVGrid(
                    columns: PageMetrics.cardColumns(compact, minimum: 250, spacing: 12),
                    spacing: UIScale.pt(12)
                ) {
                    ForEach(accounts) { account in
                        if let platform = model.platform(for: account) {
                            accountCard(account, platform: platform)
                        }
                    }
                }
            }
        }
    }

    private func accountCard(_ account: SocialAccount, platform: SocialPlatform) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack(alignment: .top) {
                SocialAvatar(
                    image: model.avatars[account.id], initials: account.initials, name: account.name
                )
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(platform.name).font(.edithText(.headline)).lineLimit(2)
                    Text(account.name).font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    SocialAccountActions(model: model, account: account)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Manage \(account.name)")
            }
            HStack {
                Button {
                    model.open(account)
                } label: {
                    Label("Open account", systemImage: "arrow.up.right")
                }
                if model.currentTab != nil {
                    Button {
                        model.open(account, beside: true)
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .accessibilityLabel("Open \(account.name) side by side")
                    .help("Open beside the focused account, including accounts on another platform")
                }
            }
        }
        .padding(UIScale.pt(18)).frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(dark)).clipShape(RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(DashSkin.line(dark)))
        .contextMenu { SocialAccountActions(model: model, account: account) }
        .draggable("social-account:\(account.id)")
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, value.hasPrefix("social-account:"),
                let id = UUID(uuidString: String(value.dropFirst(15)))
            else { return false }
            model.reorderAccount(id, before: account)
            return true
        }
        .disabled(model.busy)
    }

    private func layoutMenu(_ tab: SocialWorkspaceTab) -> some View {
        Menu {
            ForEach(model.catalog.profiles) { profile in
                let accounts = model.catalog.accounts.filter {
                    $0.profileID == profile.id && !tab.layout.contains($0.id.uuidString)
                }
                if !accounts.isEmpty {
                    Menu(profile.name) {
                        ForEach(accounts) { account in
                            Menu(
                                "\(model.platform(for: account)?.name ?? "Website"): \(account.name)"
                            ) {
                                Button("Open to the right") { model.open(account, beside: true) }
                                Button("Open below") {
                                    model.open(account, beside: true, side: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Columns", systemImage: "rectangle.split.2x1") { model.arrange(.horizontal) }
                .disabled(tab.layout.paneCount < 2)
            Button("Rows", systemImage: "rectangle.split.1x2") { model.arrange(.vertical) }
                .disabled(tab.layout.paneCount < 2)
            Button("Grid", systemImage: "square.grid.2x2") { model.grid() }
                .disabled(tab.layout.paneCount < 3)
            Button("Equalize panes") { model.equalize() }.disabled(tab.layout.paneCount < 2)
            Button("Separate into tabs") { model.separate() }.disabled(tab.layout.paneCount < 2)
        } label: {
            Label(
                tab.layout.paneCount > 1 ? "Layout" : "Side by side",
                systemImage: "rectangle.split.2x1")
        }
        .disabled(model.busy)
    }
}
