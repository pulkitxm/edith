import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import SwiftUI

struct HostExtensionReview: View {
    @Bindable var marketplace: HostMarketplace
    let suites: HostSuiteSelection
    let entry: HostExtension
    let presenter: (any HostExtensionContentPresenting)?
    let open: (() -> Void)?
    let done: () -> Void
    let navigation: HostSettingsNavigation?
    @State private var reviewed: ExtensionPackage?
    @State private var task: Task<Void, Never>?
    @State private var notice: String?
    @Environment(\.colorScheme) private var scheme

    init(
        marketplace: HostMarketplace, suites: HostSuiteSelection, entry: HostExtension,
        presenter: (any HostExtensionContentPresenting)?, open: (() -> Void)?,
        done: @escaping () -> Void, navigation: HostSettingsNavigation? = nil
    ) {
        self.marketplace = marketplace; self.suites = suites; self.entry = entry
        self.presenter = presenter; self.open = open; self.done = done
        self.navigation = navigation
        _reviewed = State(initialValue: marketplace.available[entry.id])
    }

    private var dark: Bool { scheme == .dark }
    private var state: HostExtensionRowState { .init(entry, marketplace: marketplace) }
    private var active: Bool { marketplace.surfaceAvailability.activeIDs.contains(entry.id) }
    private var installed: Bool { marketplace.installed[entry.id] != nil }
    private var downloaded: Bool { marketplace.installedVersions[entry.id]?.isEmpty == false }
    private var busy: Bool { owning || marketplace.isBusy(entry.id) }
    private var owning: Bool { task != nil || suites.working }
    private var pendingDisable: Bool { marketplace.sessions.pendingDisableIDs.contains(entry.id) }
    private var pending: Bool { marketplace.pendingRemovalIDs.contains(entry.id) || pendingDisable }
    private var permissions: [HostPermission] {
        entry.requiredPermissions + entry.optionalPermissions
    }

    static func settingsRequest(
        id: String, marketplace: HostMarketplace, presentationID: UUID = UUID()
    ) -> HostExtensionContentRequest? {
        HostExtensionSettingsPolicy.request(
            id: id, installed: marketplace.installed[id], state: marketplace.sessions.states[id],
            activeVersion: marketplace.sessions.versions[id],
            pendingDisable: marketplace.sessions.pendingDisableIDs.contains(id),
            pendingRemoval: marketplace.pendingRemovalIDs.contains(id),
            presentationID: presentationID)
    }

    static func idealHeight(for id: String) -> Double {
        switch id {
        case "micMute", "systemStats", "audioMixer": 300
        case "attention": 440
        case "machines": 420
        case "lidAwake": 400
        case "music": 460
        case "focusDim", "hinge", "colorPicker", "keystrokeHighlight": 430
        case "system": 500
        case "presenter": 580
        default: 620
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let request = Self.settingsRequest(id: entry.id, marketplace: marketplace) {
                    HostExtensionContent(
                        marketplace: marketplace, extensionID: request.extensionID,
                        location: request.location, section: request.section,
                        presenter: presenter, openMarketplace: done, navigation: navigation
                    )
                    .id(navigation?.delivery.id)
                } else {
                    ScrollView { overview.padding(UIScale.pt(24)) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(
            width: PresentationMetrics.width(560),
            height: PresentationMetrics.height(Self.idealHeight(for: entry.id))
        )
        .pageSurface()
        .tracksWindowVisibility()
        .interactiveDismissDisabled(owning)
        .onDisappear {
            task?.cancel(); navigation?.delivery.reject()
        }
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(12)) {
            Image(systemName: entry.symbolName)
                .font(.system(size: UIScale.pt(16), weight: .semibold))
                .foregroundStyle(active ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(34), height: UIScale.pt(34))
                .background(
                    active ? DashSkin.accent(dark).opacity(0.14) : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(entry.title).font(.edithText(.headline)).accessibilityAddTraits(.isHeader)
                Text(state.status).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .lineLimit(1).monospacedDigit()
            }
            Spacer()
            if installed, !marketplace.pendingRemovalIDs.contains(entry.id) {
                Toggle(
                    isOn: Binding(
                        get: { active },
                        set: { wanted in
                            perform { await suites.select(entry, enabled: wanted) }
                        })
                ) { Text("\(entry.title) enabled") }
                .labelsHidden().toggleStyle(.switch).tint(DashSkin.accent(dark)).disabled(busy)
                .accessibilityLabel("\(entry.title) enabled")
            }
        }
        .padding(.horizontal, UIScale.pt(24)).padding(.vertical, UIScale.pt(16))
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HostExtensionPreview(entry: entry, dark: dark)
                .frame(maxWidth: .infinity).frame(height: UIScale.pt(88))
                .background(
                    DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            Text(HostMarketplaceCatalog.subtitles[entry.id] ?? entry.title)
                .font(.edithText(.body)).fixedSize(horizontal: false, vertical: true)
            if let facts = HostMarketplacePackageSummary(
                candidate: reviewed ?? marketplace.installed[entry.id],
                downloadedVersions: marketplace.installedVersions[entry.id] ?? []
            ).line {
                Text(facts).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !permissions.isEmpty {
                HostPermissionInfoButton(
                    permissions: permissions,
                    label: permissions.count == 1
                        ? permissions[0].displayName : "\(permissions.count) permissions")
            }
            Text(guidance).font(.edithText(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice {
                Text(notice).font(.edithText(.caption)).foregroundStyle(.orange)
            }
            if let error = marketplace.error {
                Text(error).font(.edithText(.caption)).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var guidance: String {
        if pendingDisable {
            return
                "Cleanup is still pending. Home and Notch cards are inactive. System resources may remain until cleanup or macOS approval finishes."
        }
        if marketplace.pendingRemovalIDs.contains(entry.id) {
            return "Removal is pending. Remove it again to finish cleanup."
        }
        if !installed {
            if downloaded, reviewed != nil {
                return "This version of Edith needs a newer package. Update to keep using it."
            }
            if downloaded { return "No package for this version of Edith is published yet." }
            return reviewed == nil
                ? "Verified download information is unavailable. Refresh to review the package."
                : "Download to add this extension. It starts right away."
        }
        if HostExtensionSettingsPolicy.policy(for: entry.id) == .active {
            return "Turn this extension on to change its settings."
        }
        if let route = HostNavigationCatalog.route(extensionID: entry.id) {
            let page = HostNavigationCatalog.pages.first { $0.id == route.page }?.title
            return "Open \(page ?? entry.title) from the sidebar to use this extension."
        }
        return "This extension's controls are available from its menu or shortcut."
    }

    private var footer: some View {
        HStack(spacing: UIScale.pt(8)) {
            if downloaded, !busy {
                Button("Remove", role: .destructive) {
                    perform { await marketplace.remove(id: entry.id) }
                }
                .buttonStyle(.edith(.borderless)).foregroundStyle(.red)
            }
            if busy { LoadingIndicator().frame(width: UIScale.pt(16), height: UIScale.pt(16)) }
            Spacer()
            primary
            Button("Done", action: done).keyboardShortcut(.defaultAction).disabled(owning)
        }
        .padding(.horizontal, UIScale.pt(18)).padding(.vertical, UIScale.pt(12))
        .background(.bar)
    }

    @ViewBuilder private var primary: some View {
        if pending {
            EmptyView()
        } else if !installed, reviewed == nil {
            Button("Refresh") { refresh() }.buttonStyle(.edith(.secondary))
                .disabled(busy || marketplace.refreshingCatalog)
        } else if !installed {
            Button(downloaded ? "Update" : "Download") { download() }
                .buttonStyle(.edith(.primary)).disabled(busy)
        } else if marketplace.updateAvailable(id: entry.id) {
            Button("Update") { perform { await marketplace.download(id: entry.id) } }
                .buttonStyle(.edith(.primary)).disabled(busy)
        } else if active, HostNavigationCatalog.route(extensionID: entry.id) != nil, let open {
            Button("Open", action: open).buttonStyle(.edith(.secondary)).disabled(busy)
        }
    }

    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        task = Task {
            defer { task = nil }
            await action()
        }
    }

    private func refresh() {
        perform {
            await marketplace.checkForUpdates()
            guard !Task.isCancelled else { return }
            reviewed = marketplace.available[entry.id]
        }
    }

    private func download() {
        guard let reviewed else { return }
        perform {
            await marketplace.download(id: entry.id, expectedPackage: reviewed)
            guard !Task.isCancelled else { return }
            if marketplace.available[entry.id] != reviewed {
                self.reviewed = marketplace.available[entry.id]
                notice = "The package changed. Review its version and size before downloading."
            } else if marketplace.installed[entry.id] != nil {
                await suites.select(entry, enabled: true)
            }
        }
    }
}
