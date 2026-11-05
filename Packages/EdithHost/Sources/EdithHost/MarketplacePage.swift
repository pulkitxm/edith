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
        requestedSettings: Binding<HostSettingsNavigation?> = .constant(nil)
    ) {
        self.marketplace = marketplace; self.presenter = presenter;
        self.openExtension = openExtension
        _requestedSettings = requestedSettings
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

    var body: some View {
        PageWorkspace {
            PageHeader("Extensions") {
                headerControls
            } accessory: {
                SearchField(placeholder: "Search extensions", text: $search, typeAhead: true)
                    .accessibilityLabel("Find extensions")
                HostPageTabPicker(
                    title: "Show", selection: $scope, options: HostMarketplaceScope.allCases,
                    label: scopeTitle)
                HostPageTabPicker(
                    title: "Extension category", selection: $category,
                    options: ["all"] + HostMarketplaceCatalog.suites.map(\.id),
                    label: { id in
                        HostMarketplaceCatalog.suites.first { $0.id == id }?.title ?? "All"
                    })
            }
        } content: {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: UIScale.pt(24)) {
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

    @ViewBuilder private var headerControls: some View {
        if let batch = marketplace.batch {
            HostMarketplaceBatchStatus(
                batch: batch, progress: marketplace.batchProgress,
                bytesPerSecond: marketplace.batchBytesPerSecond)
        } else if !marketplace.updatableIDs.isEmpty, !showsMigrationBanner {
            Button("Update all (\(marketplace.updatableIDs.count))") {
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

    @ViewBuilder private var notices: some View {
        if let error = marketplace.error {
            PageNotice(error, tone: .error)
        }
        if marketplace.offline {
            PageNotice(
                marketplace.installed.isEmpty && !marketplace.downloadedIDs.isEmpty
                    ? "You are offline. Connect to download extensions compatible with this app."
                    : "You are offline. Installed extensions keep working.",
                symbol: "wifi.slash")
        } else if showsMigrationBanner {
            HStack(spacing: UIScale.pt(10)) {
                Image(systemName: "arrow.down.circle").foregroundStyle(DashSkin.accent(dark))
                Text(
                    migrating.count == 1
                        ? "1 extension needs an update for this version of Edith."
                        : "\(migrating.count) extensions need an update for this version of Edith."
                )
                .font(.edithText(.callout)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: UIScale.pt(8))
                Button(
                    marketplace.updatableIDs.count > migrating.count ? "Update all" : "Update now"
                ) {
                    Task { await marketplace.updateAll() }
                }
                .buttonStyle(.edith(.primary)).disabled(suites.working)
            }
            .padding(.horizontal, UIScale.pt(14)).padding(.vertical, UIScale.pt(10))
            .widgetBar(
                cornerRadius: 12, fill: DashSkin.accent(dark).opacity(0.08),
                stroke: DashSkin.accent(dark).opacity(0.25))
        }
    }

    private func scopeTitle(_ value: HostMarketplaceScope) -> String {
        value == .updates && !marketplace.updatableIDs.isEmpty
            ? "Updates (\(marketplace.updatableIDs.count))" : value.title
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: UIScale.pt(compact ? 260 : 300)), spacing: UIScale.pt(12))]
    }

    private var skeletons: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            SkeletonBlock(width: 160, height: 16)
            LazyVGrid(columns: columns, spacing: UIScale.pt(12)) {
                ForEach(0..<8, id: \.self) { _ in HostExtensionCardSkeleton() }
            }
        }
    }

    @ViewBuilder private var empty: some View {
        if !query.isEmpty {
            PageEmptyState(
                symbolName: "magnifyingglass", title: "No extensions found",
                message: "Nothing matches \"\(query)\". Try a different word, or browse by category.",
                primary: PageAction("Clear search", identifier: "extensions.clear-search") {
                    search = ""
                })
                .frame(minHeight: UIScale.pt(280))
        } else if scope == .installed {
            PageEmptyState(
                symbolName: "puzzlepiece.extension", title: "Nothing installed yet",
                message: "Extensions add tools to Edith. Pick one from Browse and it is ready in seconds.",
                primary: PageAction("Browse extensions", identifier: "extensions.browse") {
                    scope = .all
                })
                .frame(minHeight: UIScale.pt(280))
        } else if scope == .updates {
            PageEmptyState(
                symbolName: "checkmark.circle", title: "Everything is up to date",
                message: "Updates appear here when a newer version of an installed extension is available.",
                primary: PageAction("Check for updates", identifier: "extensions.check") {
                    Task { await marketplace.checkForUpdates() }
                })
                .frame(minHeight: UIScale.pt(280))
        } else {
            PageEmptyState(
                symbolName: marketplace.offline ? "wifi.slash" : "puzzlepiece.extension",
                title: "No extensions available",
                message: marketplace.offline
                    ? "Connect to the internet to browse extensions."
                    : "This group has no extensions available right now.",
                primary: marketplace.offline
                    ? PageAction("Try again", identifier: "extensions.retry") {
                        Task { await marketplace.checkForUpdates() }
                    } : nil
            )
            .frame(minHeight: UIScale.pt(280))
        }
    }

    private var featuredSection: some View {
        let featured = HostMarketplaceCatalog.featured(
            filtered, installed: Set(marketplace.installed.keys))
        return Group {
            if !featured.isEmpty {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    PageSectionHeader(
                        "Recommended", subtitle: "A good place to start. Each one is ready in seconds.")
                    LazyVGrid(columns: columns, spacing: UIScale.pt(12)) {
                        ForEach(featured) { entry in card(entry) }
                    }
                }
            }
        }
    }

    private var automaticUpdates: some View {
        Toggle(isOn: $marketplace.automaticallyUpdatesExtensions) {
            Text("Update extensions automatically").font(.edithText(.callout))
        }
        .toggleStyle(.switch).controlSize(.small).tint(DashSkin.accent(dark))
        .padding(.horizontal, UIScale.pt(4))
    }

    private func section(_ suite: HostMarketplaceSuite, entries: [HostExtension]) -> some View {
        let enabled = suites.enabled(suite)
        let onCount = entries.filter { HostExtensionRowState($0, marketplace: marketplace).on }
            .count
        return VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                Text(suite.title).font(.edithText(.headline)).accessibilityAddTraits(.isHeader)
                Text(enabled ? "\(onCount) of \(entries.count) on" : "Off")
                    .font(.edithText(.caption)).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: UIScale.pt(8))
                Toggle(
                    "",
                    isOn: Binding(
                        get: { suites.enabled(suite) },
                        set: { value in Task { await suites.setEnabled(value, suite: suite) } })
                )
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .tint(DashSkin.accent(dark)).disabled(suites.working)
                .accessibilityLabel("\(suite.title) suite enabled")
            }
            .padding(.horizontal, UIScale.pt(4))
            Text(suite.subtitle).font(.edithText(.caption)).foregroundStyle(.secondary)
                .padding(.horizontal, UIScale.pt(4))
            LazyVGrid(columns: columns, spacing: UIScale.pt(12)) {
                ForEach(entries) { entry in card(entry).id(entry.id) }
            }
        }
    }

    private func card(_ entry: HostExtension) -> some View {
        let state = HostExtensionRowState(entry, marketplace: marketplace)
        return HostExtensionCard(
            entry: entry, state: state, tagline: HostMarketplaceCatalog.tagline(entry),
            hint: state.stage == .ready ? HostExtensionActions.hint(for: entry) : nil,
            canCancel: marketplace.canCancelDownload(entry.id),
            details: { selected = entry },
            perform: { action in perform(action, entry: entry) },
            cancel: { marketplace.cancelDownload(id: entry.id) },
            toggle: { value in Task { await suites.select(entry, enabled: value) } })
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
