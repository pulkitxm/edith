import EdithExtensionSupport
import EdithExtensionUI
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
        filterAccounts(profileID: accountProfileFilterID)
    }

    func filteredAccounts(in profile: SocialProfile) -> [SocialAccount] {
        filterAccounts(profileID: profile.id)
    }

    private func filterAccounts(profileID: UUID?) -> [SocialAccount] {
        let query = accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = catalog.accounts.filter { account in
            (profileID == nil || account.profileID == profileID)
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

struct SocialAccountSearch: View {
    @Bindable var model: SocialManagerModel

    var body: some View {
        SearchField(placeholder: "Search accounts", text: $model.accountSearch)
            .accessibilityLabel("Search social accounts")
    }
}

struct SocialOpenAccountsMenu: View {
    let model: SocialManagerModel
    let accounts: [SocialAccount]

    var body: some View {
        PageMenuChip("Open all (\(accounts.count))", icon: .layers) {
            Button("Open all in tabs") { model.openAccounts(accounts) }
            if accounts.count > 1 {
                Menu("Open all side by side") {
                    ForEach(model.templates(for: accounts.count)) { template in
                        Button(template.title) { model.openAccounts(accounts, layout: template) }
                    }
                }
            }
        }
        .disabled(accounts.isEmpty || model.busy)
        .help("Open every matching account using its saved browser session")
    }
}

struct SocialAccountListRow: View {
    let model: SocialManagerModel
    let account: SocialAccount
    var compactRow = false
    var onOpen: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var padding: CGFloat { UIScale.pt(compactRow ? 8 : compact ? 10 : 14) }

    var body: some View {
        Button {
            model.open(account)
            onOpen?()
        } label: {
            HStack(spacing: UIScale.pt(12)) {
                HStack(spacing: UIScale.pt(8)) {
                    SocialAvatar(
                        image: model.avatars[account.id], initials: account.initials,
                        name: account.name, size: compactRow ? 28 : 36)
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(account.handle ?? account.name).font(
                            .edithText(.subheadline).weight(.semibold)
                        ).lineLimit(1)
                        Text(
                            [model.profile(for: account)?.name, model.platform(for: account)?.name]
                                .compactMap { $0 }.joined(separator: " · ")
                        )
                        .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                accessory.hidden().accessibilityHidden(true)
            }
            .padding(padding)
            .background(
                model.focusedAccount?.id == account.id
                    ? DashSkin.accent(scheme == .dark).opacity(0.12)
                    : DashSkin.paper2(scheme == .dark),
                in: RoundedRectangle(cornerRadius: UIScale.pt(10))
            )
        }
        .buttonStyle(SocialCardButtonStyle(cornerRadius: 10))
        .accessibilityLabel("Open \(model.accountTitle(account))")
        .overlay(alignment: .trailing) {
            accessory.padding(.trailing, padding)
        }
        .contextMenu { SocialAccountActions(model: model, account: account) }
        .herdrDraggable(.pane(account.id.uuidString), simultaneous: true)
    }

    private var accessory: some View {
        HStack(spacing: UIScale.pt(12)) {
            if model.paneIsOpen(account.id.uuidString) {
                EdithIconView(.dot, size: UIScale.pt(16))
                    .frame(width: UIScale.pt(6), height: UIScale.pt(6))
                    .foregroundStyle(DashSkin.accent(scheme == .dark)).accessibilityLabel("Open")
            }
            Menu {
                SocialAccountActions(model: model, account: account)
            } label: {
                EdithIconView(.more).accessibilityHidden(true)
            }
            .borderlessMenu().fixedSize()
            .accessibilityLabel("Manage \(model.accountTitle(account))")
        }
    }
}
