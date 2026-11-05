import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

enum HostMarketplaceKeys {
    static let expandedExtension = "extensionsExpand"
}

struct MarketplacePage: View {
    @Bindable var marketplace: HostMarketplace
    var presenter: (any HostExtensionContentPresenting)? = nil
    var openExtension: ((String) -> Void)? = nil
    @Binding var requestedSettings: HostSettingsNavigation?
    @State private var search = ""
    @State private var category = "all"
    @State private var scope = HostMarketplaceScope.all
    @State private var selected: HostExtension?
    @State private var suites: HostSuiteSelection
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    init(
        marketplace: HostMarketplace, presenter: (any HostExtensionContentPresenting)? = nil,
        openExtension: ((String) -> Void)? = nil,
        requestedSettings: Binding<HostSettingsNavigation?> = .constant(nil),
        scope: HostMarketplaceScope = .all, search: String = ""
    ) {
        self.marketplace = marketplace; self.presenter = presenter;
        self.openExtension = openExtension
        _requestedSettings = requestedSettings
        _scope = State(initialValue: scope)
        _search = State(initialValue: search)
        _suites = State(
            initialValue: HostSuiteSelection(
                marketplace: marketplace,
                defaults: UserDefaults(suiteName: marketplace.identity.defaultsSuite)!))
    }

    private var catalogEntries: [HostExtension] {
        marketplace.entries.filter {
            marketplace.available[$0.id] != nil
                || marketplace.installedVersions[$0.id]?.isEmpty == false
        }
    }
    private var filtered: [HostExtension] {
        HostMarketplaceCatalog.filter(
            catalogEntries, query: search, category: category, scope: scope,
            installed: Set(marketplace.installed.keys).union(marketplace.downloadedIDs),
            updatable: Set(marketplace.updatableIDs))
    }
    private var loadingCatalog: Bool {
        catalogEntries.isEmpty
            && (marketplace.refreshingCatalog
                || (!marketplace.catalogKnown && marketplace.error == nil && !marketplace.offline))
    }
    private var showsFeatured: Bool {
        query.isEmpty && category == "all" && scope == .all
    }
    private var dark: Bool { scheme == .dark }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var migrating: [String] {
        marketplace.updatableIDs.filter { marketplace.installed[$0] == nil }
    }
    private var showsMigrationBanner: Bool {
        !marketplace.offline && marketplace.batch == nil && !migrating.isEmpty
    }

    private var filtersScroll: Bool { HostMarketplaceLayout.filtersScroll(zoom: UIScale.current) }
    private var emptyStyle: PageEmptyStateStyle { filtersScroll ? .compact : .regular }
    private var emptyHeight: CGFloat {
        filtersScroll ? 0 : UIScale.pt(HostMarketplaceLayout.emptyHeight)
    }

    private var catalogUnavailable: Bool {
        catalogEntries.isEmpty && !loadingCatalog
            && (marketplace.error != nil || marketplace.offline)
    }

    var body: some View {
        PageWorkspace {
            PageHeader(
                "Extensions",
                subtitle:
                    "Add tools to Edith. Each one installs in seconds and can be turned off any time.",
                divider: true
            ) {
                headerControls
            } accessory: {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.filterRowSpacing)) {
                    searchField
                    if !filtersScroll { filters }
                }
            }
        } content: {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.filterRowSpacing)) {
                        if filtersScroll { filters }
                        groups
                    }
                    .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
                    .pageContent(compact)
                }
                .scrollIndicators(.automatic)
                .onAppear { handleDeepLink(proxy) }
            }
        }
        .pageTask { await marketplace.refreshCatalogIfStale() }
        .onChange(of: requestedSettings, initial: true) {
            guard let request = requestedSettings else { return }
            let id = request.delivery.extensionID
            guard presenter != nil,
                let entry = marketplace.entries.first(where: { $0.id == id }),
                HostExtensionReview.settingsRequest(id: id, marketplace: marketplace) != nil
            else { request.delivery.reject(); return }
            search = ""; category = "all"; scope = .all; selected = entry
        }
        .onChange(of: selected?.id) {
            if let request = requestedSettings, selected?.id != request.delivery.extensionID {
                request.delivery.reject()
            }
        }
        .onDisappear { requestedSettings?.delivery.reject() }
        .navigationTitle("Extensions")
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: category)
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: scope)
        .edithSheet(item: $selected) { entry in detail(entry) }
    }

    private var searchField: some View {
        SearchField(placeholder: "Search extensions", text: $search, typeAhead: true)
            .accessibilityLabel("Find extensions")
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(HostMarketplaceLayout.groupSpacing)) {
            if catalogUnavailable {
                unavailable
            } else {
                notices
                if loadingCatalog {
                    skeletons
                } else if filtered.isEmpty {
                    empty
                } else {
                    if showsFeatured { featuredSection }
                    ForEach(HostMarketplaceCatalog.groups(filtered), id: \.suite.id) {
                        group in
                        section(group.suite, entries: group.entries)
                    }
                }
                automaticUpdates
            }
        }
    }

    private var filters: some View {
        PageFilterBar {
            PageFilterRow("Show") {
                ForEach(HostMarketplaceScope.allCases, id: \.self) { option in
                    PageChip(scopeTitle(option), active: scope == option) { scope = option }
                }
            }
            PageFilterRow("Category") {
                if compact {
                    PageMenuChip(categoryTitle(category), active: category != "all") {
                        ForEach(categories, id: \.self) { id in
                            Button(categoryTitle(id)) { category = id }
                        }
                    }
                } else {
                    ForEach(categories, id: \.self) { id in
                        PageChip(categoryTitle(id), active: category == id) { category = id }
                    }
                }
            }
        }
    }

    private var categories: [String] { ["all"] + HostMarketplaceCatalog.suites.map(\.id) }

    private func categoryTitle(_ id: String) -> String {
        HostMarketplaceCatalog.suites.first { $0.id == id }?.title ?? "All"
    }

    private var headerControls: some View {
        HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            if let batch = marketplace.batch {
                HostMarketplaceBatchStatus(
                    batch: batch, progress: marketplace.batchProgress,
                    bytesPerSecond: marketplace.batchBytesPerSecond)
            } else if !marketplace.updatableIDs.isEmpty, !showsMigrationBanner {
                Button("Update All (\(marketplace.updatableIDs.count))") {
                    Task { await marketplace.updateAll() }
                }
                .buttonStyle(.edith(.primary)).disabled(suites.working)
            }
            Button {
                Task { await marketplace.checkForUpdates() }
            } label: {
                Text(marketplace.refreshingCatalog ? "Checking…" : "Check for Updates")
            }
            .buttonStyle(.edith(.secondary))
            .disabled(suites.working || marketplace.refreshingCatalog)
        }
    }

    @ViewBuilder private var notices: some View {
        if let error = marketplace.error, !marketplace.offline {
            PageNotice(error, tone: .error)
        }
        if marketplace.offline {
            PageNotice(
                marketplace.installed.isEmpty && !marketplace.downloadedIDs.isEmpty
                    ? "Connect to the internet to download extensions that work with this version of Edith."
                    : "Installed extensions keep working. Connect to the internet to get new ones.",
                title: "You are offline", symbol: "wifi.slash")
        } else if showsMigrationBanner {
            PageNotice(
                migrating.count == 1
                    ? "1 extension needs an update to work with this version of Edith."
                    : "\(migrating.count) extensions need an update to work with this version of Edith.",
                title: "Updates needed", symbol: "arrow.down.circle"
            ) {
                EmptyView()
            } actions: {
                Button(
                    marketplace.updatableIDs.count > migrating.count ? "Update All" : "Update Now"
                ) {
                    Task { await marketplace.updateAll() }
                }
                .buttonStyle(.edith(.primary)).disabled(suites.working)
            }
        }
    }

    private var unavailable: some View {
        PageEmptyState(
            symbolName: marketplace.offline ? "wifi.slash" : "wifi.exclamationmark",
            title: marketplace.offline ? "You are offline" : "Extensions could not load",
            message: marketplace.offline
                ? "Connect to the internet to browse and download extensions."
                : (marketplace.error ?? "The extension list is unavailable right now.")
                    + " Your installed extensions keep working.",
            primary: PageAction("Try Again", identifier: "extensions.retry") {
                Task { await marketplace.checkForUpdates() }
            },
            style: emptyStyle
        )
        .frame(minHeight: emptyHeight)
        .disabled(marketplace.refreshingCatalog)
    }

    private func scopeTitle(_ value: HostMarketplaceScope) -> String {
        value == .updates && !marketplace.updatableIDs.isEmpty
            ? "Updates (\(marketplace.updatableIDs.count))" : value.title
    }

    private var skeletons: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            SkeletonReplica("Loading extensions") {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    SkeletonBlock(width: 140, height: 16)
                    SkeletonBlock(width: 260, height: 12)
                }
            }
            HostExtensionListSkeleton(rows: 9)
        }
    }

    @ViewBuilder private var empty: some View {
        if !query.isEmpty {
            PageEmptyState(
                symbolName: "magnifyingglass", title: "No extensions found",
                message:
                    "Nothing matches \"\(query)\". Try a different word, or browse by category.",
                primary: PageAction("Clear Search", identifier: "extensions.clear-search") {
                    search = ""
                }, style: emptyStyle
            )
            .frame(minHeight: emptyHeight)
        } else if scope == .installed {
            PageEmptyState(
                symbolName: "puzzlepiece.extension", title: "Nothing installed yet",
                message:
                    "Extensions add tools to Edith. Pick one from Browse and it is ready in seconds.",
                primary: PageAction("Browse Extensions", identifier: "extensions.browse") {
                    scope = .all
                }, style: emptyStyle
            )
            .frame(minHeight: emptyHeight)
        } else if scope == .updates {
            PageEmptyState(
                symbolName: marketplace.offline ? "wifi.slash" : "checkmark.circle",
                title: marketplace.offline
                    ? "Updates need a connection" : "Everything is up to date",
                message: marketplace.offline
                    ? "Connect to the internet to look for newer versions of your extensions."
                    : "Updates appear here when a newer version of an installed extension is available.",
                primary: PageAction(
                    marketplace.offline ? "Try Again" : "Check for Updates",
                    identifier: "extensions.check"
                ) {
                    Task { await marketplace.checkForUpdates() }
                }, style: emptyStyle
            )
            .frame(minHeight: emptyHeight)
        } else {
            PageEmptyState(
                symbolName: "puzzlepiece.extension", title: "Nothing in this category yet",
                message:
                    "New extensions arrive with Edith updates. Browse all extensions in the meantime.",
                primary: PageAction("Show All", identifier: "extensions.all") { category = "all" },
                style: emptyStyle
            )
            .frame(minHeight: emptyHeight)
        }
    }

    private var featuredSection: some View {
        let featured = HostMarketplaceCatalog.featured(
            filtered, installed: Set(marketplace.installed.keys))
        return Group {
            if !featured.isEmpty {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                    PageSectionHeader(
                        "Recommended", subtitle: "A good place to start if you are new to Edith.")
                    HostExtensionList(entries: featured, row: row)
                }
            }
        }
    }

    private var automaticUpdates: some View {
        HStack(alignment: .center, spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text("Update extensions automatically").font(.edithText(.body))
                Text("New versions download and install in the background.")
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: UIScale.pt(12))
            Toggle(
                "Update extensions automatically", isOn: $marketplace.automaticallyUpdatesExtensions
            )
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .tint(DashSkin.accent(dark))
        }
        .padding(.horizontal, UIScale.pt(PageMetrics.cardPadding))
        .padding(.vertical, UIScale.pt(12))
        .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
    }

    private func section(_ suite: HostMarketplaceSuite, entries: [HostExtension]) -> some View {
        let enabled = suites.enabled(suite)
        let installedCount = entries.filter { marketplace.installed[$0.id] != nil }.count
        let onCount = entries.filter { HostExtensionRowState($0, marketplace: marketplace).on }
            .count
        return VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            PageSectionHeader(suite.title, subtitle: suite.subtitle) {
                if installedCount > 0 {
                    HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                        Text(enabled ? "\(onCount) of \(entries.count) on" : "Suite off")
                            .font(.edithText(.callout)).foregroundStyle(.secondary)
                            .monospacedDigit()
                        Toggle(
                            "\(suite.title) suite enabled",
                            isOn: Binding(
                                get: { suites.enabled(suite) },
                                set: { value in
                                    Task { await suites.setEnabled(value, suite: suite) }
                                })
                        )
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .tint(DashSkin.accent(dark)).disabled(suites.working)
                    }
                }
            }
            HostExtensionList(entries: entries, row: row)
        }
    }

    private func row(_ entry: HostExtension) -> HostExtensionRow {
        let state = HostExtensionRowState(entry, marketplace: marketplace)
        return HostExtensionRow(
            entry: entry, state: state, tagline: HostMarketplaceCatalog.tagline(entry),
            note: note(entry, state: state),
            canCancel: marketplace.canCancelDownload(entry.id),
            details: { selected = entry },
            perform: { action in perform(action, entry: entry) },
            cancel: { marketplace.cancelDownload(id: entry.id) },
            toggle: { value in Task { await suites.select(entry, enabled: value) } })
    }

    private func note(_ entry: HostExtension, state: HostExtensionRowState) -> String? {
        switch state.stage {
        case .ready: HostExtensionActions.hint(for: entry)
        case .notInstalled:
            marketplace.available[entry.id].map {
                ByteCountFormatter.string(fromByteCount: $0.downloadBytes, countStyle: .file)
            }
        default: nil
        }
    }

    private func perform(_ action: HostExtensionRowState.Action, entry: HostExtension) {
        Task {
            switch action {
            case .open:
                marketplace.acknowledgeReady(entry.id)
                HostExtensionActions.open(
                    entry, active: true, openPage: openExtension, showDetails: { selected = $0 })
            case .update where marketplace.installed[entry.id] != nil:
                await marketplace.download(id: entry.id)
            case .download, .update, .retry:
                await suites.select(entry, enabled: true)
            case .retryDisable:
                await suites.select(entry, enabled: false)
            case .remove:
                await marketplace.remove(id: entry.id)
            }
        }
    }

    private func detail(_ entry: HostExtension) -> some View {
        HostExtensionReview(
            marketplace: marketplace, suites: suites, entry: entry, presenter: presenter,
            open: openExtension.map { callback in
                {
                    selected = nil; callback(entry.id)
                }
            },
            done: { selected = nil },
            navigation: requestedSettings.flatMap {
                $0.delivery.extensionID == entry.id ? $0 : nil
            })
    }

    private func handleDeepLink(_ proxy: ScrollViewProxy) {
        let defaults = UserDefaults(suiteName: marketplace.identity.defaultsSuite)!
        guard let id = defaults.string(forKey: HostMarketplaceKeys.expandedExtension),
            let entry = marketplace.entries.first(where: { $0.id == id })
        else { return }
        defaults.removeObject(forKey: HostMarketplaceKeys.expandedExtension); search = ""
        category = "all"; scope = .all
        DispatchQueue.main.async {
            proxy.scrollTo(entry.id, anchor: .center); selected = entry
        }
    }
}

enum HostMarketplaceLayout {
    static let groupSpacing = 32.0
    static let emptyHeight = 360.0
    static let pinnedFiltersZoomLimit = 1.6

    static func filtersScroll(zoom: Double) -> Bool { zoom >= pinnedFiltersZoomLimit }
}

struct HostMarketplaceBatchStatus: View {
    let batch: HostExtensionBatch
    let progress: Double
    let bytesPerSecond: Double

    private var title: String {
        "Downloading \(min(batch.finished + 1, batch.total)) of \(batch.total)"
    }

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            LoadingProgress(value: progress).frame(width: UIScale.pt(80))
            Text(title).font(.edithText(.callout)).monospacedDigit()
            if bytesPerSecond >= 1 {
                Text(HostExtensionOperation.rate(bytesPerSecond)).font(.edithText(.caption))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
