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
        _tab = State(
            initialValue: hasSettings && marketplace.installed[entry.id] != nil ? .settings : .about
        )
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

    static let aboutHeight = 680.0

    static func idealHeight(for id: String) -> Double {
        switch id {
        case "systemStats": 340
        case "calendar": 360
        case "audioMixer": 380
        case "micMute": 420
        case "keepAwake": 620
        case "lidAwake": 640
        default: aboutHeight
        }
    }

    static func sheetHeight(for id: String, showingSettings: Bool) -> Double {
        showingSettings ? idealHeight(for: id) : aboutHeight
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
                    ScrollView { overview.padding(UIScale.pt(HostExtensionDetailLayout.padding)) }
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity)
            .clipped()
            Divider()
            footer.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }
        .frame(
            width: PresentationMetrics.width(640),
            height: PresentationMetrics.height(
                Self.sheetHeight(
                    for: entry.id, showingSettings: settingsRequest != nil && tab == .settings))
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
            HostExtensionIcon(entry: entry, size: 40)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(entry.title).font(.edithText(.headline)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(state.stage == .ready ? HostExtensionActions.hint(for: entry) : state.status)
                    .font(.edithText(.caption))
                    .foregroundStyle(state.stage == .ready ? DashSkin.accent(dark) : .secondary)
                    .lineLimit(1).monospacedDigit()
            }
            .layoutPriority(1)
            Spacer(minLength: UIScale.pt(8))
            if state.progress != nil || (state.action != nil && state.action != .remove) {
                HostInstallControl(
                    title: entry.title, state: state,
                    canCancel: marketplace.canCancelDownload(entry.id),
                    perform: handle, cancel: { marketplace.cancelDownload(id: entry.id) }
                )
                .disabled(owning && state.progress == nil)
            }
            EdithSegmentedPicker(
                "View", selection: $tab, options: [Tab.settings, .about],
                label: { $0 == .settings ? "Settings" : "About" }
            )
            .labelsHidden().frame(width: UIScale.pt(160))
            if installed, !marketplace.pendingRemovalIDs.contains(entry.id) {
                Toggle(
                    isOn: Binding(
                        get: { active },
                        set: { wanted in
                            perform { await suites.select(entry, enabled: wanted) }
                        })
                ) { Text("\(entry.title) enabled") }
                .labelsHidden().toggleStyle(.edithSwitch).controlSize(.small)
                .disabled(busy)
                .accessibilityLabel("\(entry.title) enabled")
            }
        }
        .padding(.horizontal, UIScale.pt(HostExtensionDetailLayout.padding))
        .padding(.vertical, UIScale.pt(12))
    }

    private var problem: String? {
        if state.stage == .failed { return state.status }
        guard let error = marketplace.error, error != state.status else { return nil }
        let elsewhere = marketplace.failures.contains { $0.key != entry.id && $0.value == error }
        return elsewhere ? nil : error
    }

    private var overview: some View {
        let guide = entry.guide
        return VStack(
            alignment: .leading, spacing: UIScale.pt(HostExtensionDetailLayout.sectionSpacing)
        ) {
            HostExtensionHero(
                entry: entry, tagline: HostMarketplaceCatalog.tagline(entry),
                categoryTitle: categoryTitle
            ) {
                heroAction
            }
            if state.stage == .ready {
                PageNotice(
                    HostExtensionActions.hint(for: entry), title: "\(entry.title) is ready",
                    tone: .success)
            }
            if let notice {
                PageNotice(notice, tone: .warning)
            }
            if let problem {
                PageNotice(problem, title: "Something went wrong", tone: .error)
            }
            if let guidance {
                PageNotice(guidance, tone: .information)
            }
            HostExtensionArtwork(entry: entry)
            if let summary = guide?.summary, !summary.isEmpty {
                Text(summary).font(.edithText(.body)).foregroundStyle(DashSkin.inkSoft(dark))
                    .lineSpacing(UIScale.pt(2))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let steps = guide?.pageSteps, !steps.isEmpty {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
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
                Text(facts).font(.edithText(.caption)).foregroundStyle(DashSkin.inkFaint(dark))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var heroAction: some View {
        if pending {
            EmptyView()
        } else if !installed, reviewed == nil, !downloaded {
            Button("Check Again") { refresh() }.buttonStyle(.edith(.primary)).controlSize(.large)
                .disabled(busy || marketplace.refreshingCatalog)
        } else {
            HostInstallControl(
                title: entry.title, state: state, large: true,
                canCancel: marketplace.canCancelDownload(entry.id),
                perform: handle, cancel: { marketplace.cancelDownload(id: entry.id) }
            )
            .disabled(owning && state.progress == nil)
        }
    }

    private var guidance: String? {
        if pendingDisable {
            return
                "Turning off is still finishing. Its Home and notch cards stay inactive until cleanup or a macOS approval completes."
        }
        if marketplace.pendingRemovalIDs.contains(entry.id) {
            return "Removal did not finish. Remove it again to clean up the rest."
        }
        if let staged = marketplace.restartPending[entry.id] {
            return
                "Version \(staged.version) is downloaded. \(entry.title) keeps running its current version until Edith restarts."
        }
        if !installed {
            if downloaded, reviewed != nil {
                return "This version of Edith needs a newer package. Update to keep using it."
            }
            if downloaded { return "No package for this version of Edith is published yet." }
            if reviewed == nil {
                return "Download details are not available yet. Check again to load them."
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
        .padding(.horizontal, UIScale.pt(HostExtensionDetailLayout.padding))
        .padding(.vertical, UIScale.pt(12))
        .background(DashSkin.paper2(dark))
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
        case .restart:
            HostApplicationRelaunch.perform()
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
