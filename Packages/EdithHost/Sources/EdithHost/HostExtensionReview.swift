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
    @State private var tab: Tab
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
        let hasSettings =
            Self.settingsRequest(id: entry.id, marketplace: marketplace) != nil
        _tab = State(initialValue: hasSettings && marketplace.installed[entry.id] != nil ? .settings : .about)
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

    private enum Tab: Hashable { case settings, about }

    private var settingsRequest: HostExtensionContentRequest? {
        Self.settingsRequest(id: entry.id, marketplace: marketplace)
    }
    private var categoryTitle: String? { HostMarketplaceCatalog.suite(for: entry)?.title }

    var body: some View {
        VStack(spacing: 0) {
            if settingsRequest != nil { settingsHeader; Divider() }
            Group {
                if let request = settingsRequest, tab == .settings {
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
            width: PresentationMetrics.width(640),
            height: PresentationMetrics.height(max(Self.idealHeight(for: entry.id), 680))
        )
        .pageSurface()
        .tracksWindowVisibility()
        .interactiveDismissDisabled(owning)
        .onChange(of: marketplace.available[entry.id]) {
            if reviewed == nil { reviewed = marketplace.available[entry.id] }
        }
        .onDisappear {
            task?.cancel(); navigation?.delivery.reject()
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: UIScale.pt(12)) {
            HostExtensionIcon(symbolName: entry.symbolName, active: active, size: 34)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(entry.title).font(.edithText(.headline)).accessibilityAddTraits(.isHeader)
                Text(state.status).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .lineLimit(1).monospacedDigit()
            }
            Spacer()
            EdithSegmentedPicker(
                "View", selection: $tab, options: [Tab.settings, .about],
                label: { $0 == .settings ? "Settings" : "About" }
            )
            .labelsHidden().frame(width: UIScale.pt(170))
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
        .padding(.horizontal, UIScale.pt(24)).padding(.vertical, UIScale.pt(14))
    }

    private var overview: some View {
        let guide = entry.guide
        return VStack(alignment: .leading, spacing: UIScale.pt(24)) {
            HostExtensionHero(
                entry: entry, tagline: HostMarketplaceCatalog.tagline(entry),
                categoryTitle: categoryTitle, active: state.on || installed
            ) {
                heroAction
            }
            if let notice {
                Text(notice).font(.edithText(.callout)).foregroundStyle(.orange)
            }
            if state.stage == .failed {
                Text(state.status).font(.edithText(.callout)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = marketplace.error {
                Text(error).font(.edithText(.callout)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let guidance {
                Text(guidance).font(.edithText(.callout)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary = guide?.summary, !summary.isEmpty {
                Text(summary).font(.edithText(.body)).foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if HostExtensionPreview.hasPreview(entry.id) {
                HostExtensionPreview(entry: entry, dark: dark)
                    .frame(maxWidth: .infinity).frame(height: UIScale.pt(96))
                    .background(
                        DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            }
            if let steps = guide?.pageSteps, !steps.isEmpty {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    PageSectionHeader("How it works")
                    PageGuideSteps(steps: steps, columns: 1)
                }
            }
            HostExtensionPlacementList(placements: HostExtensionActions.placements(for: entry))
            HostExtensionPermissionList(
                required: entry.requiredPermissions, optional: entry.optionalPermissions)
            if let examples = guide?.examples, !examples.isEmpty {
                HostExtensionExamples(examples: examples)
            }
            if let facts = HostMarketplacePackageSummary(
                candidate: reviewed ?? marketplace.installed[entry.id],
                downloadedVersions: marketplace.installedVersions[entry.id] ?? []
            ).line {
                Text(facts).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var heroAction: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            if pending {
                EmptyView()
            } else if !installed, reviewed == nil, !downloaded {
                Button("Refresh") { refresh() }.buttonStyle(.edith(.primary)).controlSize(.large)
                    .disabled(busy || marketplace.refreshingCatalog)
            } else {
                HostInstallControl(
                    title: entry.title, state: state, large: true,
                    canCancel: marketplace.canCancelDownload(entry.id),
                    perform: handle, cancel: { marketplace.cancelDownload(id: entry.id) })
                    .disabled(owning && state.progress == nil)
            }
            if state.stage == .ready {
                Text(HostExtensionActions.hint(for: entry)).font(.edithText(.callout))
                    .foregroundStyle(DashSkin.accent(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var guidance: String? {
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
            if reviewed == nil {
                return "Verified download information is unavailable. Refresh to review the package."
            }
        }
        return nil
    }

    private var footer: some View {
        HStack(spacing: UIScale.pt(8)) {
            if downloaded, !busy {
                Button("Remove", role: .destructive) {
                    perform { await marketplace.remove(id: entry.id) }
                }
                .buttonStyle(.edith(.borderless)).foregroundStyle(.red)
            }
            Spacer()
            Button("Close") {
                marketplace.acknowledgeReady(entry.id)
                done()
            }
            .buttonStyle(.edith(.secondary)).keyboardShortcut(.cancelAction).disabled(owning)
        }
        .padding(.horizontal, UIScale.pt(18)).padding(.vertical, UIScale.pt(12))
        .background(.bar)
    }

    private func handle(_ action: HostExtensionRowState.Action) {
        let fresh = !installed
        switch action {
        case .open:
            marketplace.acknowledgeReady(entry.id)
            if let open { open() } else { done() }
        case .download:
            download()
        case .retry where fresh, .update where fresh:
            download()
        case .update:
            perform { await marketplace.download(id: entry.id) }
        case .retry:
            perform { await suites.select(entry, enabled: true) }
        case .retryDisable:
            perform { await suites.select(entry, enabled: false) }
        case .remove:
            perform { await marketplace.remove(id: entry.id) }
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
        let wasInstalled = installed
        perform {
            notice = nil
            await marketplace.download(id: entry.id, expectedPackage: reviewed)
            guard !Task.isCancelled else { return }
            if marketplace.available[entry.id] != reviewed {
                self.reviewed = marketplace.available[entry.id]
                notice = "The package changed. Review its version and size before downloading."
            } else if marketplace.installed[entry.id] != nil {
                await suites.select(entry, enabled: true)
                if !wasInstalled, active { marketplace.markReady(entry.id) }
            }
        }
    }
}
