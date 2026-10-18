import EdithKit
import SwiftUI

struct SocialManagerPage: View {
    @Environment(\.windowSessionOwner) private var owner
    @StateObject private var fallback = WindowSessionOwner()
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @State private var addingAccount = false
    @State private var addingPlatform = false
    @State private var editingAccount: SocialAccount?
    @State private var clearingAccount: SocialAccount?
    @State private var removingAccount: SocialAccount?
    private let providedModel: SocialManagerModel?

    init(model: SocialManagerModel? = nil) { providedModel = model }

    private var model: SocialManagerModel {
        providedModel ?? owner?.socialManager ?? fallback.socialManager
    }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        PageWorkspace {
            PageHeader("Social Manager") {
                if !model.showingAccounts, let tab = model.currentTab {
                    layoutMenu(tab)
                }
                Button {
                    addingAccount = true
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .disabled(!model.load.hasContent || model.busy)
            } accessory: {
                Text("Separate accounts. One workspace.")
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
        .edithSheet(isPresented: $addingAccount, dismissible: false) {
            SocialAccountEditor(model: model, platformID: model.platformID)
        }
        .edithSheet(isPresented: $addingPlatform, dismissible: false) {
            SocialPlatformEditor(model: model)
        }
        .edithSheet(item: $editingAccount, dismissible: false) { account in
            SocialAccountEditor(model: model, account: account, platformID: account.platformID)
        }
        .confirmationDialog(
            "Clear this account's session?",
            isPresented: Binding(
                get: { clearingAccount != nil }, set: { if !$0 { clearingAccount = nil } }),
            titleVisibility: .visible, presenting: clearingAccount
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
                get: { removingAccount != nil }, set: { if !$0 { removingAccount = nil } }),
            titleVisibility: .visible, presenting: removingAccount
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
                tabChip("Accounts", symbol: "square.grid.2x2", selected: model.showingAccounts) {
                    model.showingAccounts = true
                }.id("accounts")
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
                state: model.load.state, title: "Social accounts",
                message: model.load.errorMessage ?? "Loading your platforms and accounts.",
                layout: .cards, retry: { model.start() }
            ) {
                VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                    PageSectionHeader("Platforms") {
                        Button("Add website", systemImage: "plus") { addingPlatform = true }
                    }
                    LazyVGrid(
                        columns: PageMetrics.cardColumns(compact, minimum: 210, spacing: 12),
                        spacing: UIScale.pt(12)
                    ) {
                        ForEach(model.catalog.platforms) { platform in platformCard(platform) }
                    }
                    if let platform = model.selectedPlatform {
                        accounts(for: platform)
                    } else {
                        Text(
                            "Choose a platform to see its accounts, or add a website with its URL."
                        )
                        .font(.edithText(.body)).foregroundStyle(.secondary)
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

    private func platformCard(_ platform: SocialPlatform) -> some View {
        let count = model.catalog.accounts.filter { $0.platformID == platform.id }.count
        let selected = model.platformID == platform.id
        return Button {
            model.platformID = platform.id
        } label: {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                HStack {
                    Image(systemName: platform.symbol).font(.edithText(.title2)).foregroundStyle(
                        .tint)
                    Spacer()
                    Text("\(count) \(count == 1 ? "account" : "accounts")")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                Text(platform.name).font(.edithText(.headline)).foregroundStyle(.primary)
                Text(platform.website.host ?? platform.website.absoluteString)
                    .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(UIScale.pt(18)).frame(maxWidth: .infinity, alignment: .leading)
            .background(DashSkin.paper2(dark))
            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(12)))
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                    selected ? DashSkin.accent(dark) : DashSkin.line(dark)))
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func accounts(for platform: SocialPlatform) -> some View {
        let accounts = model.catalog.accounts.filter { $0.platformID == platform.id }
        return VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            PageSectionHeader("\(platform.name) accounts") {
                Button("Add account", systemImage: "plus") { addingAccount = true }
                    .disabled(model.busy)
            }
            if accounts.isEmpty {
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    Text("Your first \(platform.name) account").font(.edithText(.headline))
                    Text(
                        "Give it a name, then sign in on the website. Add more accounts for separate logins."
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
                    ForEach(accounts) { account in accountCard(account, platform: platform) }
                }
            }
        }
    }

    private func accountCard(_ account: SocialAccount, platform: SocialPlatform) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack(alignment: .top) {
                Text(account.initials).font(.edithText(.title3))
                    .frame(width: UIScale.pt(42), height: UIScale.pt(42))
                    .background(DashSkin.accent(dark).opacity(0.15)).clipShape(Circle())
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(account.name).font(.edithText(.headline)).lineLimit(2)
                    Text(platform.name).font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Edit name and badge") { editingAccount = account }
                    Button("Clear login session…", role: .destructive) { clearingAccount = account }
                    Button("Remove account…", role: .destructive) { removingAccount = account }
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
        .disabled(model.busy)
    }

    private func layoutMenu(_ tab: SocialWorkspaceTab) -> some View {
        Menu {
            ForEach(model.catalog.platforms) { platform in
                let accounts = model.catalog.accounts.filter {
                    $0.platformID == platform.id && !tab.layout.contains($0.id.uuidString)
                }
                if !accounts.isEmpty {
                    Menu(platform.name) {
                        ForEach(accounts) { account in
                            Menu(account.name) {
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
