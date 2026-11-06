import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct SocialManagerPage: View {
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
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
    private let model: SocialManagerModel

    init(model: SocialManagerModel, drag: HerdrDragCoordinator? = nil) {
        self.model = model
        _drag = State(initialValue: drag ?? HerdrDragCoordinator())
    }

    private var dark: Bool { scheme == .dark }

    var body: some View {
        @Bindable var model = model
        PageWorkspace {
            PageHeader(
                "Social Manager",
                subtitle: "Keep every social account signed in, grouped by person, brand or client."
            ) {
                HStack(spacing: UIScale.pt(8)) {
                    SocialLibraryViewPicker(model: model)
                    if let account = model.focusedAccount, let profile = model.profile(for: account)
                    {
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
                        Label("Add", edith: .plus)
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .disabled(!model.load.hasContent || model.busy)
                    .help(
                        model.busy
                            ? "Wait for the current change to finish"
                            : "Add a profile or an account")
                }
            }
            tabs
            if let message = model.message {
                HStack {
                    Text(message).font(.edithText(.caption)).textSelection(.enabled)
                    Spacer()
                    Button {
                        model.message = nil
                    } label: {
                        EdithIconView(.close)
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .accessibilityLabel("Dismiss message")
                }
                .padding(UIScale.pt(10)).pageGutter(compact)
            }
            Divider()
        } content: {
            HStack(spacing: 0) {
                if railOpen, !compact {
                    accountRail.frame(width: UIScale.pt(264))
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
        .overlay { HerdrDragOverlay(drag: drag, store: model) }
        .herdrDropFrame(HerdrDropGeometry.pageKey)
        .coordinateSpace(name: HerdrDragCoordinator.space)
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
        }
        .onDisappear { drag.cancel() }
        .workspaceCommands { [weak model] command in
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
            PageIconChip(icon: .sidebarLeft, label: "Show accounts") {
                if compact { compactRailPresented.toggle() } else { railOpen.toggle() }
            }
            .help("Show or hide the account list")
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
                        Label(model.libraryView.rawValue, edith: .people).font(
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
                                        .font(.edithText(.caption).weight(.semibold))
                                        .monospacedDigit()
                                        .padding(.horizontal, UIScale.pt(5)).padding(
                                            .vertical, UIScale.pt(1)
                                        )
                                        .background(
                                            DashSkin.paper(dark).opacity(0.8), in: Capsule())
                                }
                                Button {
                                    model.closeTab(tab.id)
                                } label: {
                                    EdithIconView(.close)
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
                errorTitle: "Your profiles could not be opened",
                message: model.load.errorMessage.map {
                    "Your saved profiles and accounts could not be opened. \($0) Try again in a moment."
                } ?? "Loading your profiles and connected accounts.",
                layout: .cards, retry: { model.start() }
            ) {
                if model.catalog.profiles.isEmpty {
                    firstProfileState
                } else if model.catalog.accounts.isEmpty, model.libraryView != .profiles {
                    firstAccountState
                } else {
                    VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                        if model.libraryView != .profiles {
                            allAccounts
                        } else if let profile = model.selectedProfile {
                            Button("All profiles", edith: .chevronLeft) {
                                model.profileID = nil
                            }
                            .buttonStyle(.edithDefault)
                            accounts(for: profile)
                        } else {
                            PageSectionHeader(
                                "Profiles",
                                subtitle:
                                    "Keep the social accounts for each person, brand or client together."
                            )
                            SocialTileGrid(items: model.catalog.profiles) { profileCard($0) }
                        }
                        Label(
                            "Sign in on each website once. Cookies and website storage stay in that account's own persistent browser session on this Mac.",
                            edith: .shield
                        )
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, UIScale.pt(PageMetrics.top))
                }
            }
        }
    }

    private var firstProfileState: some View {
        PageEmptyState(
            icon: .people,
            title: "Keep every social account in one place",
            message:
                "Group the accounts for each person, brand or client into a profile, then open them side by side with each one staying signed in.",
            steps: [
                PageGuideStep(
                    icon: .personAdd, title: "Create a profile",
                    detail: "Name it after a person, brand or client."),
                PageGuideStep(
                    icon: .plus, title: "Add accounts",
                    detail: "Pick Instagram, YouTube, X, LinkedIn or any website."),
                PageGuideStep(
                    icon: .layoutLeft, title: "Sign in once, work side by side",
                    detail: "Each account keeps its own login on this Mac."),
            ],
            primary: PageAction(
                "Create your first profile", icon: .plus, identifier: "social.first-profile"
            ) {
                addingProfile = true
            },
            footnote:
                "Logins stay in each account's own browser session on this Mac. Edith never sees your passwords."
        )
        .frame(minHeight: UIScale.pt(420))
        .pageFillViewport()
    }

    private var firstAccountState: some View {
        let profile = model.catalog.profiles.first
        return PageEmptyState(
            icon: .plus,
            title: "Add your first account",
            message:
                "Choose a website such as Instagram, YouTube, X or LinkedIn, then sign in once. It stays signed in the next time you open it.",
            primary: PageAction(
                "Add account", icon: .plus, identifier: "social.first-account"
            ) {
                accountProfile = profile
                addingAccount = true
            },
            secondary: PageAction(
                "Add another profile", icon: .personAdd
            ) {
                addingProfile = true
            },
            footnote: profile.map {
                "It will be added to \($0.name). You can move on later from the profile menu."
            }
        )
        .frame(minHeight: UIScale.pt(420))
        .pageFillViewport()
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
        .buttonStyle(SocialCardButtonStyle(cornerRadius: 12))
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
        return VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: UIScale.pt(12)) {
                    profileIdentity(profile)
                    Spacer(minLength: UIScale.pt(8))
                    profileActionBar(profile).fixedSize()
                }
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    profileIdentity(profile)
                    profileActionBar(profile)
                }
            }
            .disabled(model.busy)
            if !model.accounts(in: profile).isEmpty {
                SocialAccountSearch(model: model)
                SocialOpenAccountsMenu(model: model, accounts: accounts)
            }
            if accounts.isEmpty, !model.accounts(in: profile).isEmpty {
                Text("No accounts match these filters.").font(.edithText(.body)).foregroundStyle(
                    .secondary)
                Button("Reset filters") { model.resetAccountFilters() }
                    .buttonStyle(.edithDefault)
            } else if accounts.isEmpty {
                PageEmptyState(
                    icon: .plus, title: "Add accounts to \(profile.name)",
                    message:
                        "Choose Instagram, YouTube, X, LinkedIn or another website, then sign in once. Only the accounts you add appear in this profile.",
                    primary: PageAction(
                        "Add account", icon: .plus, identifier: "social.profile-add-account"
                    ) {
                        accountProfile = profile
                        addingAccount = true
                    }
                )
                .frame(minHeight: UIScale.pt(300)).disabled(model.busy)
            } else {
                accountTiles(accounts)
            }
        }
    }

    private func accountTiles(_ accounts: [SocialAccount]) -> some View {
        SocialTileGrid(items: accounts.filter { model.platform(for: $0) != nil }) { account in
            if let platform = model.platform(for: account) {
                accountCard(account, platform: platform)
            }
        }
    }

    private func profileIdentity(_ profile: SocialProfile) -> some View {
        let count = model.accounts(in: profile).count
        return HStack(spacing: UIScale.pt(12)) {
            SocialAvatar(
                image: model.profileAvatars[profile.id], initials: profile.initials,
                name: profile.name, size: 44)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(profile.name).font(.edithText(.headline)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    profile.email
                        ?? (count == 0
                            ? "No accounts yet"
                            : count == 1 ? "1 connected account" : "\(count) connected accounts")
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func profileActionBar(_ profile: SocialProfile) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            SocialEmailMenu(model: model, profile: profile)
            PageMenuChip("Manage profile", icon: .more) {
                profileActions(profile)
                Button("Add custom website") { addingPlatform = true }
            }
            if !model.accounts(in: profile).isEmpty {
                Button("Add account", edith: .plus) { addingAccount = true }
                    .buttonStyle(.edith(.secondary))
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
                    EdithIconView(.more).foregroundStyle(.secondary)
                }
                .borderlessMenu().fixedSize()
                .accessibilityLabel("Manage \(account.name)")
            }
            HStack {
                Button {
                    model.open(account)
                } label: {
                    Label("Open account", edith: .arrowUpRight)
                }
                if model.currentTab != nil {
                    Button {
                        model.open(account, beside: true)
                    } label: {
                        EdithIconView(.layoutLeft)
                    }
                    .accessibilityLabel("Open \(account.name) side by side")
                    .help("Open beside the focused account, including accounts on another platform")
                }
            }
            .buttonStyle(.edithDefault)
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
                if model.catalog.accounts.isEmpty {
                    Text("Accounts you add appear here, ready to open in one click.")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    SocialAccountSearch(model: model)
                    SocialOpenAccountsMenu(model: model, accounts: model.filteredAccounts)
                    Text("\(model.filteredAccounts.count) accounts").font(.edithText(.caption))
                        .foregroundStyle(.secondary)
                }
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
                if !model.catalog.profiles.isEmpty {
                    PageChip("Manage profiles") {
                        model.browse(.profiles); compactRailPresented = false
                    }
                }
            }
            .pageGutter(compact)
            .padding(.vertical, UIScale.pt(PageMetrics.top))
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
                .buttonStyle(.edithDefault)
            } else if model.libraryView == .list {
                LazyVStack(spacing: UIScale.pt(8)) {
                    ForEach(model.filteredAccounts) {
                        SocialAccountListRow(model: model, account: $0)
                    }
                }
            } else {
                accountTiles(model.filteredAccounts)
            }
        }
    }

}
