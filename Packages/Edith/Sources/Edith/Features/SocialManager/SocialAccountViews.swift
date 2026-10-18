import EdithKit
import SwiftUI

enum SocialLibraryView: String, CaseIterable {
    case profiles = "Profiles"
    case accounts = "Accounts"
    case list = "List"
}

enum SocialAccountStatus: String, CaseIterable {
    case all = "All accounts"
    case open = "Open accounts"
    case closed = "Closed accounts"
}

enum SocialAccountSort: String, CaseIterable {
    case manual = "Manual order"
    case profile = "Profile"
    case platform = "Platform"
    case username = "Username"
}

extension SocialManagerModel {
    var availablePlatforms: [SocialPlatform] {
        catalog.platforms.filter { platform in
            catalog.accounts.contains { $0.platformID == platform.id }
        }
    }

    var filteredAccounts: [SocialAccount] {
        let query = accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = catalog.accounts.filter { account in
            (accountProfileFilterID == nil || account.profileID == accountProfileFilterID)
                && (platformFilterID == nil || account.platformID == platformFilterID)
                && (accountStatus == .all
                    || (paneIsOpen(account.id.uuidString) == (accountStatus == .open)))
                && (query.isEmpty
                    || [
                        account.name, account.username, account.handle, profile(for: account)?.name,
                        platform(for: account)?.name,
                    ]
                    .compactMap { $0 }.contains { $0.localizedStandardContains(query) })
        }
        guard accountSort != .manual else { return matches }
        return matches.sorted { left, right in
            let order = accountSortKey(left).localizedStandardCompare(accountSortKey(right))
            return order == .orderedSame
                ? accountTitle(left).localizedStandardCompare(accountTitle(right))
                    == .orderedAscending
                : order == .orderedAscending
        }
    }

    private func accountSortKey(_ account: SocialAccount) -> String {
        switch accountSort {
        case .manual: account.name
        case .profile: profile(for: account)?.name ?? ""
        case .platform: platform(for: account)?.name ?? ""
        case .username: account.username ?? account.name
        }
    }

    func resetAccountFilters() {
        accountProfileFilterID = nil; platformFilterID = nil; accountSearch = "";
        accountStatus = .all
    }

    func browse(_ view: SocialLibraryView) {
        if libraryView == .profiles || view == .profiles { profileID = nil }
        libraryView = view
        showingAccounts = true
    }

    func openAccounts(_ accounts: [SocialAccount], layout: HerdrLayoutTemplate? = nil) {
        guard !busy, !accounts.isEmpty else { return }
        for (index, account) in accounts.enumerated() {
            if layout != nil, index > 0 {
                open(account, beside: true)
            } else {
                openInNewTab(account)
            }
        }
        if let layout, let tab = currentTab {
            focus(accounts[0].id.uuidString)
            arrange(tab.id.uuidString, as: layout)
            activateFocusedBrowser()
        }
    }
}

struct SocialLibraryViewPicker: View {
    let model: SocialManagerModel

    var body: some View {
        EdithSegmentedPicker(
            "Account view",
            selection: Binding(get: { model.libraryView }, set: { model.browse($0) }),
            options: SocialLibraryView.allCases, label: { $0.rawValue }
        )
        .frame(width: UIScale.pt(230))
    }
}

struct SocialAccountFilters: View {
    @Bindable var model: SocialManagerModel
    var vertical = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            if vertical {
                profilePicker
                platformPicker
                statusPicker
                sortPicker
            } else {
                HStack(spacing: UIScale.pt(10)) {
                    profilePicker; platformPicker
                }
                HStack(spacing: UIScale.pt(10)) {
                    statusPicker; sortPicker
                }
            }
            TextField("Search accounts, profiles or platforms", text: $model.accountSearch)
                .textFieldStyle(.roundedBorder).font(.edithText(.subheadline))
                .accessibilityLabel("Search social accounts")
            if model.accountProfileFilterID != nil || model.platformFilterID != nil
                || !model.accountSearch.isEmpty || model.accountStatus != .all
            {
                Button("Reset filters") { model.resetAccountFilters() }
                    .font(.edithText(.caption))
            }
        }
    }

    private var profilePicker: some View {
        Picker("Profile", selection: $model.accountProfileFilterID) {
            Text("All profiles").tag(Optional<UUID>.none)
            ForEach(model.catalog.profiles) { Text($0.name).tag(Optional($0.id)) }
        }.font(.edithText(.subheadline))
    }

    private var platformPicker: some View {
        Picker("Platform", selection: $model.platformFilterID) {
            Text("All platforms").tag(Optional<UUID>.none)
            ForEach(model.availablePlatforms) { Text($0.name).tag(Optional($0.id)) }
        }.font(.edithText(.subheadline))
    }

    private var statusPicker: some View {
        Picker("Status", selection: $model.accountStatus) {
            ForEach(SocialAccountStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.font(.edithText(.subheadline))
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $model.accountSort) {
            ForEach(SocialAccountSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.font(.edithText(.subheadline))
    }
}

struct SocialOpenAccountsMenu: View {
    let model: SocialManagerModel
    let accounts: [SocialAccount]

    var body: some View {
        Menu {
            Button("Open all in tabs") { model.openAccounts(accounts) }
            if accounts.count > 1 {
                Menu("Open all side by side") {
                    ForEach(model.templates(for: accounts.count)) { template in
                        Button(template.title) { model.openAccounts(accounts, layout: template) }
                    }
                }
            }
        } label: {
            Label("Open all (\(accounts.count))", systemImage: "rectangle.stack.badge.plus")
        }
        .disabled(accounts.isEmpty || model.busy)
        .help("Open every matching account using its saved browser session")
    }
}

struct SocialAccountListRow: View {
    let model: SocialManagerModel
    let account: SocialAccount
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        HStack(spacing: UIScale.pt(12)) {
            SocialAvatar(
                image: model.avatars[account.id], initials: account.initials, name: account.name,
                size: 36)
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(model.accountTitle(account)).font(.edithText(.subheadline).weight(.semibold))
                    .lineLimit(1)
                Text(model.platform(for: account)?.name ?? "Website").font(.edithText(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                model.open(account)
            } label: {
                Image(systemName: "arrow.up.right")
            }
            .accessibilityLabel("Open \(model.accountTitle(account))")
            Menu {
                SocialAccountActions(model: model, account: account)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Manage \(model.accountTitle(account))")
        }
        .padding(UIScale.pt(compact ? 10 : 14))
        .background(
            DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10))
        )
        .contextMenu { SocialAccountActions(model: model, account: account) }
        .herdrDraggable(.pane(account.id.uuidString), simultaneous: true)
    }
}
