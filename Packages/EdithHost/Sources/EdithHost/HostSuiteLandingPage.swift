import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostSuiteAbilityGroup: Identifiable, Equatable {
    let title: String
    let entries: [HostExtension]
    var id: String { title }
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
            PageHeader(
                destination.title,
                accessory: {
                    Text(suite?.subtitle ?? "").font(.edithText(.callout)).foregroundStyle(
                        .secondary)
                })
        } content: {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    if groups.count > 1 {
                        Text(group.title.uppercased()).font(DashSkin.mono(10, weight: .semibold))
                            .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) {
                            index, entry in
                            if index > 0 { Divider().opacity(0.5) }
                            HostSuiteAbilityRow(
                                marketplace: marketplace, suites: suites, entry: entry,
                                open: { openExtension(entry.id) }, review: { selected = entry })
                        }
                    }
                    .background(
                        DashSkin.paper2(scheme == .dark),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                            DashSkin.line(scheme == .dark)))
                }
            }
            if let error = marketplace.error {
                Text(error).font(.edithText(.caption)).foregroundStyle(.red)
            }
            Text(
                "Disabled extensions keep their downloads. Manage packages and disk use in Storage."
            )
            .font(DashSkin.mono(10)).foregroundStyle(DashSkin.inkFaint(scheme == .dark))
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
        HStack(alignment: .center, spacing: UIScale.pt(11)) {
            Image(systemName: entry.symbolName).font(.system(size: UIScale.pt(15), weight: .medium))
                .foregroundStyle(active ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(20))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                HStack(spacing: UIScale.pt(6)) {
                    Text(entry.title).font(.system(size: UIScale.pt(13), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                    Text(pending ? "cleanup pending" : (installed ? "downloaded" : "optional"))
                        .font(DashSkin.mono(9.5)).foregroundStyle(DashSkin.inkFaint(dark))
                        .padding(.horizontal, UIScale.pt(5)).padding(.vertical, UIScale.pt(1))
                        .background(DashSkin.inkFaint(dark).opacity(0.1), in: Capsule())
                }
                Text(HostMarketplaceCatalog.subtitles[entry.id] ?? entry.title)
                    .font(.system(size: UIScale.pt(11.5))).foregroundStyle(DashSkin.inkSoft(dark))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: UIScale.pt(12))
            if active, HostNavigationCatalog.route(extensionID: entry.id) != nil {
                Button("Open", action: open).buttonStyle(.edith(.toolbar))
                    .accessibilityLabel("Open " + entry.title)
            }
            if installed {
                if HostExtensionSettingsPolicy.policy(for: entry.id) != .unavailable {
                    Button("Settings", action: review).buttonStyle(.edith(.toolbar))
                        .accessibilityLabel(entry.title + " settings")
                }
                Toggle(
                    "",
                    isOn: Binding(
                        get: { active },
                        set: { value in Task { await suites.select(entry, enabled: value) } })
                ).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(
                    DashSkin.accent(dark)
                )
                .disabled(pending).accessibilityLabel(entry.title + " enabled")
            } else {
                Button("Review download", action: review).buttonStyle(.edith(.toolbar))
                    .disabled(marketplace.pendingRemovalIDs.contains(entry.id))
                    .accessibilityLabel("Review " + entry.title + " download")
            }
        }
        .padding(.horizontal, UIScale.pt(14)).padding(.vertical, UIScale.pt(11))
        .disabled(marketplace.operationID != nil || suites.working)
    }
}
