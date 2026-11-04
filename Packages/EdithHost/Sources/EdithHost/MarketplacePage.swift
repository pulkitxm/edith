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

    private var filtered: [HostExtension] {
        HostMarketplaceCatalog.filter(
            marketplace.entries.filter {
                marketplace.available[$0.id] != nil
                    || marketplace.installedVersions[$0.id]?.isEmpty == false
            }, query: search, category: category)
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
                        if filtered.isEmpty, marketplace.refreshingCatalog {
                            LoadingIndicator("Loading extensions")
                                .frame(maxWidth: .infinity, minHeight: UIScale.pt(240))
                        } else if filtered.isEmpty {
                            empty
                        } else {
                            ForEach(HostMarketplaceCatalog.suites) { suite in
                                let entries = filtered.filter { $0.category == suite.id }
                                if !entries.isEmpty { section(suite, entries: entries) }
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
            search = ""; category = "all"; selected = entry
        }
        .onChange(of: selected?.id) {
            if let request = requestedSettings, selected?.id != request.delivery.extensionID {
                request.delivery.reject()
            }
        }
        .onDisappear { requestedSettings?.delivery.reject() }
        .navigationTitle("Extensions")
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: category)
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

    private var empty: some View {
        ContentUnavailableView {
            Label(
                query.isEmpty ? "No extensions available" : "No extensions found",
                systemImage: query.isEmpty ? "puzzlepiece.extension" : "magnifyingglass")
        } description: {
            Text(
                query.isEmpty
                    ? (marketplace.offline
                        ? "Connect to the internet to browse extensions."
                        : "This group has no extensions available.")
                    : "No extension matches \"\(query)\". Try another search.")
        }
        .frame(maxWidth: .infinity, minHeight: UIScale.pt(240))
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
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, UIScale.pt(54)) }
                    row(entry).id(entry.id)
                }
            }
            .edithSurface(cornerRadius: 12)
        }
    }

    private func row(_ entry: HostExtension) -> some View {
        let state = HostExtensionRowState(entry, marketplace: marketplace)
        return HostExtensionRow(
            entry: entry, state: state,
            subtitle: HostMarketplaceCatalog.subtitles[entry.id] ?? entry.title,
            details: { selected = entry },
            perform: { action in perform(action, entry: entry) },
            toggle: { value in Task { await suites.select(entry, enabled: value) } })
    }

    private func perform(_ action: HostExtensionRowState.Action, entry: HostExtension) {
        Task {
            switch action {
            case .open:
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
        defaults.removeObject(forKey: HostMarketplaceKeys.expandedExtension); search = "";
        category = "all"
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
