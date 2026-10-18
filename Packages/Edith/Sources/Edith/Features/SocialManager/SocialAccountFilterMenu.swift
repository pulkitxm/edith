import EdithKit
import SwiftUI

struct SocialAccountFilterRow: Identifiable {
    enum Action: Hashable {
        case profile(UUID?)
        case platform(UUID?)
        case status(SocialAccountStatus)
        case sort(SocialAccountSort)
        case clear
    }

    var id: Action { action }
    var section: String
    var title: String
    var action: Action
    var selected: Bool
}

extension SocialManagerModel {
    var accountFilterCount: Int {
        (accountProfileFilterID == nil ? 0 : 1) + (platformFilterID == nil ? 0 : 1)
            + (accountStatus == .all ? 0 : 1) + (accountSort == .manual ? 0 : 1)
            + (accountSearch.isEmpty ? 0 : 1)
    }

    var accountFilterSummary: String {
        var values: [String] = []
        if let profile = catalog.profiles.first(where: { $0.id == accountProfileFilterID }) {
            values.append(profile.name)
        }
        if let platform = availablePlatforms.first(where: { $0.id == platformFilterID }) {
            values.append(platform.name)
        }
        if accountStatus != .all { values.append(accountStatus.rawValue) }
        if accountSort != .manual { values.append("Sort by \(accountSort.rawValue)") }
        if !accountSearch.isEmpty { values.append("Search: \(accountSearch)") }
        return values.isEmpty ? "All accounts" : values.joined(separator: ", ")
    }

    func accountFilterRows(matching query: String) -> [SocialAccountFilterRow] {
        var rows = [
            SocialAccountFilterRow(
                section: "Profile", title: "All profiles", action: .profile(nil),
                selected: accountProfileFilterID == nil)
        ]
        for profile in catalog.profiles {
            rows.append(
                SocialAccountFilterRow(
                    section: "Profile", title: profile.name, action: .profile(profile.id),
                    selected: accountProfileFilterID == profile.id))
        }
        rows.append(
            SocialAccountFilterRow(
                section: "Platform", title: "All platforms", action: .platform(nil),
                selected: platformFilterID == nil))
        for platform in availablePlatforms {
            rows.append(
                SocialAccountFilterRow(
                    section: "Platform", title: platform.name, action: .platform(platform.id),
                    selected: platformFilterID == platform.id))
        }
        for status in SocialAccountStatus.allCases {
            rows.append(
                SocialAccountFilterRow(
                    section: "Status", title: status.rawValue, action: .status(status),
                    selected: accountStatus == status))
        }
        for sort in SocialAccountSort.allCases {
            rows.append(
                SocialAccountFilterRow(
                    section: "Sort", title: sort.rawValue, action: .sort(sort),
                    selected: accountSort == sort))
        }
        rows.append(
            SocialAccountFilterRow(
                section: "Actions", title: "Clear filters", action: .clear, selected: false))
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter {
            search.isEmpty || $0.title.localizedStandardContains(search)
                || $0.section.localizedStandardContains(search)
        }
    }

    func activateAccountFilter(_ row: SocialAccountFilterRow) {
        switch row.action {
        case .profile(let id): accountProfileFilterID = id
        case .platform(let id): platformFilterID = id
        case .status(let status): accountStatus = status
        case .sort(let sort): accountSort = sort
        case .clear:
            resetAccountFilters()
            accountSort = .manual
        }
    }
}

struct SocialAccountFilterButton: View {
    var model: SocialManagerModel
    @Binding var presented: Bool
    var onPress: () -> Void
    var onDismissed: () -> Void

    var body: some View {
        WorkspaceFilterButton(
            presented: $presented, count: model.accountFilterCount,
            label: "Filter social accounts", summary: model.accountFilterSummary,
            help: "Filter by profile, platform, or open status, and sort accounts (⇧⌘F)",
            onPress: onPress, onDismissed: onDismissed
        ) {
            SocialAccountFilterMenu(model: model, dismiss: { presented = false })
        }
    }
}

struct SocialAccountFilterMenu: View {
    var model: SocialManagerModel
    var dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        WorkspaceFilterList(
            label: "Filter social accounts", rows: model.accountFilterRows,
            section: { $0.section }, activate: model.activateAccountFilter, dismiss: dismiss
        ) { row, highlighted, action in
            WorkspaceFilterRowButton(highlighted: highlighted, action: action) {
                Image(
                    systemName: row.action == .clear
                        ? "xmark" : row.selected ? "checkmark.circle.fill" : "circle"
                )
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(row.selected ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(14), height: UIScale.pt(14))
                Text(row.title)
                    .font(.edithText(.subheadline).weight(.medium))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
            }
            .accessibilityLabel("\(row.section): \(row.title)")
            .accessibilityAddTraits(row.selected ? .isSelected : [])
        }
        .padding(UIScale.pt(12))
        .frame(width: UIScale.pt(288))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Social account filters")
    }
}
