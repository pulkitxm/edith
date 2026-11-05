import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostSuiteAbilityGroup: Identifiable, Equatable {
    let title: String
    let entries: [HostExtension]
    var id: String { title }
}

enum HostSuiteLandingSummary {
    static func installed(_ entries: [HostExtension], downloaded: Set<String>) -> Int {
        entries.filter { downloaded.contains($0.id) }.count
    }

    static func summary(_ entries: [HostExtension], downloaded: Set<String>) -> String {
        let installed = installed(entries, downloaded: downloaded)
        let available = entries.count - installed
        if entries.isEmpty { return "" }
        if available == 0 { return "All \(installed) installed" }
        if installed == 0 { return "\(available) available to get" }
        return "\(installed) installed, \(available) available to get"
    }

    static func tagline(_ entry: HostExtension) -> String {
        HostMarketplaceCatalog.tagline(entry)
    }

    static func badge(installed: Bool, active: Bool, pending: Bool) -> String? {
        if pending { return "Cleaning up" }
        if installed, !active { return "Off" }
        return nil
    }
}

enum HostSuiteLandingGroups {
    static func groups(suite: String, entries: [HostExtension]) -> [HostSuiteAbilityGroup] {
        guard suite == "desk" else { return [.init(title: "Abilities", entries: entries)] }
        let launcher: Set<String> = ["bifrost"]
        let pickers: Set<String> = ["clipboard", "emoji", "colorPicker"]
        return [
            .init(title: "Launcher", entries: entries.filter { launcher.contains($0.id) }),
            .init(title: "Pickers", entries: entries.filter { pickers.contains($0.id) }),
            .init(
                title: "Stage",
                entries: entries.filter { !launcher.union(pickers).contains($0.id) }),
        ].filter { !$0.entries.isEmpty }
    }
}

struct HostSuiteLandingPage: View {
    let marketplace: HostMarketplace
    let destination: HostNavigationPage
    var presenter: (any HostExtensionContentPresenting)? = nil
    let openExtension: (String) -> Void
    @State private var suites: HostSuiteSelection
    @State private var selected: HostExtension?
    @Environment(\.colorScheme) private var scheme

    init(
        marketplace: HostMarketplace, destination: HostNavigationPage,
        presenter: (any HostExtensionContentPresenting)? = nil,
        openExtension: @escaping (String) -> Void
    ) {
        self.marketplace = marketplace; self.destination = destination; self.presenter = presenter
        self.openExtension = openExtension
        _suites = State(
            initialValue: HostSuiteSelection(
                marketplace: marketplace,
                defaults: UserDefaults(suiteName: marketplace.identity.defaultsSuite)!))
    }

    private var suite: HostMarketplaceSuite? {
        HostMarketplaceCatalog.suites.first { $0.id == destination.suite }
    }
    private var groups: [HostSuiteAbilityGroup] {
        HostSuiteLandingGroups.groups(
            suite: destination.suite ?? "",
            entries: marketplace.entries.filter { $0.category == destination.suite })
    }

    var body: some View {
        PageScaffold(pinnedHeader: true) {
            PageHeader(subtitle: suite?.subtitle) {
                HStack(alignment: .center, spacing: UIScale.pt(12)) {
                    if let suite { PageGuideBadge(icon: suite.icon, size: 24).flushLeading() }
                    Text(destination.title)
                }
            } trailing: {
                Text(
                    HostSuiteLandingSummary.summary(
                        groups.flatMap(\.entries),
                        downloaded: Set(marketplace.installed.keys))
                )
                .font(.edithText(.caption)).monospacedDigit()
                .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
            }
        } content: {
            if let error = marketplace.error {
                PageNotice(error, title: "Something went wrong", tone: .error)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    if groups.count > 1 { PageCapsLabel(group.title) }
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) {
                            index, entry in
                            if index > 0 { Divider().padding(.leading, UIScale.pt(60)) }
                            HostSuiteAbilityRow(
                                marketplace: marketplace, suites: suites, entry: entry,
                                open: { openExtension(entry.id) }, review: { selected = entry })
                        }
                    }
                    .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
                }
            }
            Text(
                "Turning an extension off keeps its download. Manage packages and disk space in Settings, Storage."
            )
            .font(.edithText(.caption)).foregroundStyle(DashSkin.inkFaint(scheme == .dark))
            .fixedSize(horizontal: false, vertical: true)
        }
        .navigationTitle(destination.title)
        .edithSheet(item: $selected) { entry in
            HostExtensionReview(
                marketplace: marketplace, suites: suites, entry: entry,
                presenter: presenter,
                open: {
                    selected = nil; openExtension(entry.id)
                },
                done: { selected = nil })
        }
    }
}

struct HostSuiteAbilityRow: View {
    let marketplace: HostMarketplace
    let suites: HostSuiteSelection
    let entry: HostExtension
    let open: () -> Void
    let review: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var active: Bool { marketplace.surfaceAvailability.activeIDs.contains(entry.id) }
    private var installed: Bool { marketplace.installed[entry.id] != nil }
    private var pending: Bool {
        marketplace.sessions.pendingDisableIDs.contains(entry.id)
            || marketplace.pendingRemovalIDs.contains(entry.id)
    }

    var body: some View {
        let dark = scheme == .dark
        HStack(alignment: .center, spacing: UIScale.pt(12)) {
            HostExtensionIcon(
                entry: entry, size: 32,
                tint: active ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                HStack(spacing: UIScale.pt(8)) {
                    Text(entry.title).font(.edithText(.callout)).fontWeight(.medium)
                        .foregroundStyle(DashSkin.ink(dark)).lineLimit(1)
                    if let status = HostSuiteLandingSummary.badge(
                        installed: installed, active: active, pending: pending)
                    {
                        Text(status).font(.edithText(.caption2)).fontWeight(.medium)
                            .foregroundStyle(DashSkin.inkSoft(dark))
                            .padding(.horizontal, UIScale.pt(6)).padding(.vertical, UIScale.pt(2))
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .fixedSize()
                    }
                }
                Text(HostSuiteLandingSummary.tagline(entry))
                    .font(.edithText(.caption)).foregroundStyle(DashSkin.inkSoft(dark))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                if installed {
                    if active, HostNavigationCatalog.route(extensionID: entry.id) != nil {
                        Button("Open", action: open).buttonStyle(.edith(.secondary))
                            .accessibilityLabel("Open " + entry.title)
                    }
                    if HostExtensionSettingsPolicy.policy(for: entry.id) != .unavailable {
                        Button(action: review) {
                            EdithIconView(.gear)
                                .font(.system(size: UIScale.pt(13), weight: .medium))
                        }
                        .buttonStyle(.edith(.iconOnly))
                        .help(entry.title + " settings")
                        .accessibilityLabel(entry.title + " settings")
                    }
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { active },
                            set: { value in Task { await suites.select(entry, enabled: value) } })
                    ).labelsHidden().toggleStyle(.edithSwitch).controlSize(.small)
                        .disabled(pending).accessibilityLabel(entry.title + " enabled")
                        .help(active ? "Turn off " + entry.title : "Turn on " + entry.title)
                } else {
                    Button("Get", action: review).buttonStyle(.edith(.secondary))
                        .disabled(marketplace.pendingRemovalIDs.contains(entry.id))
                        .accessibilityLabel("Get " + entry.title)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, UIScale.pt(16)).padding(.vertical, UIScale.pt(12))
        .frame(minHeight: UIScale.pt(60))
        .disabled(marketplace.isBusy(entry.id) || suites.working)
    }
}
