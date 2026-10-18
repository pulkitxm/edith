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
    @State private var accountProfile: SocialProfile?
    @State private var addingPlatform = false
    @State private var addingProfile = false
    @State private var editingProfile: SocialProfile?
    @State private var removingProfile: SocialProfile?
    @State private var drag: HerdrDragCoordinator
    @State private var railOpen = true
    @State private var compactRailPresented = false
    @State private var layoutPopoverOpen = false
    @State private var filterMenu = false
    @State private var filterDismissedAt: Date?
    private let providedModel: SocialManagerModel?

    init(model: SocialManagerModel? = nil, drag: HerdrDragCoordinator? = nil) {
        providedModel = model
        _drag = State(initialValue: drag ?? HerdrDragCoordinator())
    }

    private var model: SocialManagerModel {
        providedModel ?? owner?.socialManager ?? fallback.socialManager
    }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        @Bindable var model = model
        PageWorkspace {
            PageHeader("Social Manager") {
                SocialLibraryViewPicker(model: model)
                if let account = model.focusedAccount, let profile = model.profile(for: account) {
                    SocialEmailMenu(model: model, profile: profile)
                }
                Menu {
                    Button("Add profile") { addingProfile = true }
                    ForEach(model.catalog.profiles) { profile in
                        Button("Add account to \(profile.name)") {
                            accountProfile = profile
                            addingAccount = true
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
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
            HStack(spacing: 0) {
                if railOpen, !compact {
                    accountRail.frame(width: UIScale.pt(240))
                    Divider()
                }
                ZStack {
                    library.opacity(model.showingAccounts ? 1 : 0)
                        .allowsHitTesting(model.showingAccounts).accessibilityHidden(
                            !model.showingAccounts)
                    SocialBrowserCanvas(model: model)
                        .opacity(model.showingAccounts ? 0 : 1)
                        .allowsHitTesting(!model.showingAccounts).accessibilityHidden(
                            model.showingAccounts)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .herdrDropFrame(HerdrDropGeometry.canvasKey)
            }
        }
        .overlay { HerdrDragOverlay(drag: drag, store: model, hideAgents: false) }
        .herdrDropFrame(HerdrDropGeometry.pageKey)
        .coordinateSpace(name: HerdrDragCoordinator.space)
        .onPreferenceChange(HerdrDropFrames.self) { drag.frames = $0 }
        .environment(drag)
        .onChange(of: UIScale.current) {
            drag.unit = UIScale.current; drag.gap = UIScale.pt(6)
        }
        .onChange(of: compact) { compactRailPresented = false }
        .onChange(of: addingAccount) { _, presented in
            if !presented { accountProfile = nil }
        }
        .pageTask { model.start() }
        .onAppear {
            drag.store = model
            drag.unit = UIScale.current
            drag.gap = UIScale.pt(6)
            drag.onPaneTearOff = { SocialWorkspaceWindow.open($0, from: model) }
            router?.registerWorkspaceCommands(owner: commandOwner) { [weak model] command in
                guard !addingAccount, !addingPlatform, !addingProfile,
                    editingProfile == nil, removingProfile == nil,
                    model?.editingAccount == nil, model?.clearingAccount == nil,
                    model?.removingAccount == nil
                else { return false }
                if command == .showFilters {
                    filterMenu.toggle()
                    return true
                }
                return model?.perform(command) ?? false
            }
        }
        .onDisappear {
            drag.cancel(); router?.unregisterWorkspaceCommands(owner: commandOwner)
        }
        .edithSheet(isPresented: $compactRailPresented) {
            accountRail.frame(minWidth: UIScale.pt(280), minHeight: UIScale.pt(350))
        }
        .edithSheet(isPresented: $addingAccount, dismissible: false) {
            if let profile = accountProfile ?? model.selectedProfile {
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
                account.dataStoreID == account.profileID
                    ? "This clears the profile's shared Google session, signing out Gmail and every account using it. Other profiles and separate sessions are kept."
                    : "\(account.name) will close and its cookies and website storage will be deleted. Your other accounts keep their sessions."
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
                "Remove \(account.name) from Edith. A browser session shared with another account is kept. The account on the website is kept."
            )
        }
    }

    private var tabs: some View {
        HStack(spacing: UIScale.pt(8)) {
            Button {
                if compact { compactRailPresented.toggle() } else { railOpen.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .accessibilityLabel("Show accounts").help("Show or hide the account list")
            .padding(.leading, PageMetrics.gutter(compact))
            SocialAccountFilterButton(
                model: model, presented: $filterMenu,
                onPress: {
                    if let filterDismissedAt, Date().timeIntervalSince(filterDismissedAt) < 0.35 {
                        self.filterDismissedAt = nil
                    } else {
                        filterMenu = true
                    }
                },
                onDismissed: { filterDismissedAt = Date() })
            PageTabStrip(
                selection: model.showingAccounts
                    ? "accounts" : model.selectedTabID?.uuidString ?? "accounts"
            ) {
                HStack(spacing: UIScale.pt(6)) {
                    WorkspaceTabChip(
                        id: "accounts", selected: model.showingAccounts,
                        select: {
                            model.browse(model.libraryView)
                        }
                    ) {
                        Label(model.libraryView.rawValue, systemImage: "person.2").font(
                            .edithText(.subheadline))
                    }.id("accounts")
                        .contextMenu {
                            Button("Add profile") { addingProfile = true }
                            Button("Reopen closed tab") { model.reopenClosedTab() }
                                .disabled(model.recentlyClosed.isEmpty)
                        }
                    ForEach(model.tabs) { tab in
                        WorkspaceTabChip(
                            id: tab.id.uuidString,
                            selected: !model.showingAccounts && model.selectedTabID == tab.id,
                            select: { model.select(tab) }
                        ) {
                            HStack(spacing: UIScale.pt(6)) {
                                WorkspacePaneMarks(
                                    panes: tab.layout.panes.compactMap(model.paneIdentity),
                                    dark: dark, size: 11)
                                Text(
                                    tab.layout.panes.first.flatMap(model.account).map(
                                        model.accountTitle) ?? "Account"
                                )
                                .font(.edithText(.subheadline)).lineLimit(1)
                                if tab.layout.paneCount > 1 {
                                    Text("+\(tab.layout.paneCount - 1)")
                                        .font(DashSkin.mono(9.5, weight: .semibold))
                                        .padding(.horizontal, UIScale.pt(5)).padding(
                                            .vertical, UIScale.pt(1)
                                        )
                                        .background(
                                            DashSkin.paper(dark).opacity(0.8), in: Capsule())
                                }
                                Button {
                                    model.closeTab(tab.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: UIScale.pt(9), weight: .semibold))
                                        .foregroundStyle(DashSkin.inkFaint(dark))
                                }
                                .buttonStyle(.edith(.borderless))
                                .accessibilityLabel("Close \(model.title(tab))")
                                .help("Close tab. Login sessions are kept.")
                            }
                        }
                        .id(tab.id.uuidString)
                        .contextMenu { SocialTabActions(model: model, tab: tab) }
                        .herdrDraggable(.tab(tab.id.uuidString))
                    }
                }
                .padding(.vertical, UIScale.pt(8))
            }
            if !model.showingAccounts, let tab = model.currentTab {
                WorkspaceLayoutButton(
                    split: tab.layout.paneCount > 1, presented: $layoutPopoverOpen
                ) {
                    if let current = model.currentTab {
                        SocialWorkspaceLayout(model: model, tab: current)
                    }
                }.disabled(model.busy).padding(.trailing, PageMetrics.gutter(compact))
            }
        }
        .herdrDropFrame(HerdrDropGeometry.tabBarKey)
        .background(DashSkin.paper2(dark).opacity(0.4))
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
                    if model.libraryView != .profiles {
                        allAccounts
                    } else if let profile = model.selectedProfile {
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
                            columns: PageMetrics.cardColumns(
                                compact, minimum: 250, spacing: 12, alignment: .topLeading),
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
                }.padding(.top, UIScale.pt(PageMetrics.top))
            }
        }
    }

    private func profileCard(_ profile: SocialProfile) -> some View {
        let accounts = model.accounts(in: profile)
        let platforms = model.catalog.platforms.filter { platform in
            accounts.contains { $0.platformID == platform.id }
        }
        return Button {
            model.libraryView = .profiles
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
            .padding(UIScale.pt(18)).frame(
                maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading
            )
            .background(DashSkin.paper2(dark))
            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(12)))
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                    DashSkin.line(dark)))
        }
        .buttonStyle(.edith(.borderless))
        .contextMenu { profileActions(profile) }
        .herdrDropFrame("profileCard:" + profile.id.uuidString)
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
            model.libraryView = .profiles
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
        let accounts = model.filteredAccounts(in: profile)
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
            SocialAccountSearch(model: model)
            SocialOpenAccountsMenu(model: model, accounts: accounts)
            if accounts.isEmpty, !model.accounts(in: profile).isEmpty {
                Text("No accounts match these filters.").font(.edithText(.body)).foregroundStyle(
                    .secondary)
                Button("Reset filters") { model.resetAccountFilters() }
            } else if accounts.isEmpty {
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
                    columns: PageMetrics.cardColumns(
                        compact, minimum: 250, spacing: 12, alignment: .topLeading),
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
                    Text(account.handle ?? account.name).font(.edithText(.caption)).foregroundStyle(
                        .secondary)
                    if model.libraryView != .profiles {
                        Text(model.profile(for: account)?.name ?? "")
                            .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
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
        .padding(UIScale.pt(18)).frame(
            maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading
        )
        .background(DashSkin.paper2(dark)).clipShape(RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(DashSkin.line(dark)))
        .contextMenu { SocialAccountActions(model: model, account: account) }
        .herdrDraggable(.pane(account.id.uuidString), simultaneous: true)
        .disabled(model.busy)
    }

    private var accountRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                SocialAccountSearch(model: model)
                SocialOpenAccountsMenu(model: model, accounts: model.filteredAccounts)
                Text("\(model.filteredAccounts.count) accounts").font(.edithText(.caption))
                    .foregroundStyle(.secondary)
                ForEach(model.filteredAccounts) { account in
                    SocialAccountListRow(model: model, account: account, compactRow: true) {
                        compactRailPresented = false
                    }
                    .herdrDropFrame(HerdrDropGeometry.agentPrefix + account.id.uuidString)
                    .help(
                        "Drag into a pane edge to split, its center to swap, or onto a tab to combine"
                    )
                }
                if let profile = model.selectedProfile {
                    SocialEmailMenu(model: model, profile: profile)
                }
                Button("Manage profiles") {
                    model.browse(.profiles); compactRailPresented = false
                }
            }.padding(UIScale.pt(10))
        }
        .herdrDropFrame(HerdrDropGeometry.sidebarKey)
        .background(DashSkin.paper(dark))
    }

    private var allAccounts: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            PageSectionHeader(
                "Accounts", subtitle: "Browse and open accounts across every profile."
            ) {
                SocialOpenAccountsMenu(model: model, accounts: model.filteredAccounts)
            }
            SocialAccountSearch(model: model)
            if model.filteredAccounts.isEmpty {
                Text("No accounts match these filters.").font(.edithText(.body)).foregroundStyle(
                    .secondary)
                Button("Reset filters") {
                    model.resetAccountFilters()
                }
            } else if model.libraryView == .list {
                LazyVStack(spacing: UIScale.pt(8)) {
                    ForEach(model.filteredAccounts) {
                        SocialAccountListRow(model: model, account: $0)
                    }
                }
            } else {
                LazyVGrid(
                    columns: PageMetrics.cardColumns(
                        compact, minimum: 250, spacing: 12, alignment: .topLeading),
                    spacing: UIScale.pt(12)
                ) {
                    ForEach(model.filteredAccounts) { account in
                        if let platform = model.platform(for: account) {
                            accountCard(account, platform: platform)
                        }
                    }
                }
            }
        }
    }

}
