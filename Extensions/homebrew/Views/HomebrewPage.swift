import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HomebrewMaintenanceView: View {
    @State private var model: HomebrewPageModel
    @State private var pendingUninstall: HomebrewPackage?
    @State private var kindRaw: String
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = AppTheme.accent.rawValue
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    @MainActor
    init() {
        _model = State(initialValue: HomebrewPageModel())
        _kindRaw = State(initialValue: HomebrewPackageKind.formula.rawValue)
    }

    @MainActor
    init(model: HomebrewPageModel) {
        _model = State(initialValue: model)
        _kindRaw = State(initialValue: model.initialKind.rawValue)
    }

    private var kind: HomebrewPackageKind {
        HomebrewPackageKind(rawValue: kindRaw) ?? .formula
    }

    private var theme: Color { themeColor(themeName) }

    var body: some View {
        PageWorkspace {
            if model.status?.available != false {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    filterBar
                    if model.loaded { summary }
                }
                .pageGutter(compact)
                .padding(.top, UIScale.pt(16))
                .padding(.bottom, UIScale.pt(16))
                Divider()
            }
        } content: {
            if model.status?.available == false {
                unavailableCard.scrollIndicators(.never)
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                    operationCard
                    LoadingContainer(
                        state: model.loading.state, title: "Packages could not load",
                        message: model.errorMessage ?? "Homebrew could not load its packages.",
                        retry: refreshCurrentMode, refreshing: model.loading.isRefreshing
                    ) {
                        if listingState == .packages {
                            packageCard
                        } else {
                            listingEmptyState.scrollIndicators(.never)
                        }
                    } placeholder: {
                        PageSkeleton(layout: .list, showsControls: false)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .pageGutter(compact)
                .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
                .padding(.bottom, UIScale.pt(20))
            }
        }
        .navigationRoute("view", selection: $model.mode)
        .pageTask(cancel: { model.cancelDiscovery() }) {
            async let restored = try? await model.preferredKind()
            await model.loadCachedListing(showing: kind)
            if let restored = await restored, !Task.isCancelled {
                kindRaw = restored.rawValue
                model.showCached(kind: restored)
            }
            guard !Task.isCancelled else { return }
            model.activate(kind: kind)
        }
        .onChange(of: model.mode) { _, mode in
            guard automaticActionsEnabled else { return }
            if mode == .installed {
                model.loadInstalled(kind: kind)
            } else if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.search(model.query, kind: kind)
            } else {
                model.packages = []
                model.loading.setContent()
            }
        }
        .confirmationDialog(
            "Uninstall \(pendingUninstall?.displayName ?? "this package")?",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } })
        ) {
            Button("Uninstall", role: .destructive) {
                guard let package = pendingUninstall else { return }
                pendingUninstall = nil
                model.perform(.uninstall, package: package, query: model.query, kind: kind)
            }
            Button("Cancel", role: .cancel) { pendingUninstall = nil }
        } message: {
            if pendingUninstall?.kind == .cask {
                Text(
                    "Homebrew will remove this app and the files it installed. Your documents and settings elsewhere stay where they are."
                )
            } else {
                Text(
                    "Homebrew will remove this tool and the files it installed. Anything that depends on it may stop working until you reinstall it."
                )
            }
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UIScale.pt(20)) {
                filters
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Spacer(minLength: UIScale.pt(12))
                actions
            }
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                compactFilters
                actions
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var filters: some View {
        HStack(spacing: UIScale.pt(20)) {
            HStack(spacing: UIScale.pt(8)) {
                filterLabel("Package")
                kindPicker
            }
            HStack(spacing: UIScale.pt(8)) {
                filterLabel("View")
                modePicker
            }
        }
    }

    private var compactFilters: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(spacing: UIScale.pt(8)) {
                filterLabel("Package")
                    .frame(width: UIScale.pt(64), alignment: .leading)
                kindPicker
            }
            HStack(spacing: UIScale.pt(8)) {
                filterLabel("View")
                    .frame(width: UIScale.pt(64), alignment: .leading)
                modePicker
            }
        }
    }

    private func filterLabel(_ title: String) -> some View {
        eyebrow(title.uppercased()).fixedSize()
    }

    private var kindPicker: some View {
        EdithSegmentedPicker(
            "Package kind",
            selection: Binding(
                get: { kindRaw },
                set: { value in
                    guard let kind = HomebrewPackageKind(rawValue: value) else { return }
                    kindRaw = value; model.savePreferredKind(kind)
                    if automaticActionsEnabled { refreshCurrentMode() }
                }),
            options: HomebrewPackageKind.allCases.map(\.rawValue),
            label: { HomebrewPackageKind(rawValue: $0)?.pluralTitle ?? $0 }
        )
        .labelsHidden()
        .frame(width: UIScale.pt(190))
        .disabled(model.isBusy)
        .help(
            model.isBusy
                ? "Wait for the current operation to finish."
                : "Formulae are command line tools. Casks are Mac apps.")
    }

    private var modePicker: some View {
        EdithSegmentedPicker(
            "View", selection: $model.mode, options: HomebrewPageMode.allCases,
            label: { $0.title }
        )
        .labelsHidden()
        .frame(width: UIScale.pt(170))
        .disabled(model.isMutating)
    }

    @ViewBuilder
    private var actions: some View {
        if model.mode == .search {
            HStack(spacing: UIScale.pt(8)) {
                SearchField(
                    placeholder: "Search \(kind.pluralTitle.lowercased())", text: $model.query
                )
                .frame(maxWidth: compact ? .infinity : UIScale.pt(320))
                .onSubmit { runSearch() }
                Button(action: runSearch) {
                    Text("Search").font(.edithText(.body))
                }
                .buttonStyle(.edith(.primary))
                .disabled(
                    model.isBusy
                        || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .help(
                    model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Type a package name first." : "Search Homebrew.")
            }
        } else {
            HStack(spacing: UIScale.pt(8)) {
                SearchField(placeholder: "Filter installed packages", text: $model.installedQuery)
                    .frame(maxWidth: compact ? .infinity : UIScale.pt(300))
                Button {
                    model.updatesOnly.toggle()
                } label: {
                    Label("Updates only", edith: .arrowUp)
                        .font(.edithText(.body))
                }
                .buttonStyle(.edith(.secondary, selected: model.updatesOnly))
                .accessibilityAddTraits(model.updatesOnly ? .isSelected : [])
                .help("Show only packages with a newer version available")
                Button {
                    model.loadInstalled(kind: kind)
                } label: {
                    EdithIconView(.refresh)
                }
                .buttonStyle(.edith(.iconOnly))
                .accessibilityLabel("Refresh installed packages")
                .disabled(model.isBusy)
                .help(
                    model.isBusy
                        ? "Wait for the current operation to finish."
                        : "Reload installed packages and check for updates.")
            }
        }
    }

    private var unavailableCard: some View {
        PageEmptyState(
            icon: .box,
            title: "Homebrew is not installed",
            message:
                "Homebrew is a free package manager that installs command line tools and Mac apps. Edith manages it for you once it is on this Mac.",
            steps: [
                PageGuideStep(
                    icon: .external, title: "Get Homebrew",
                    detail: "Follow the install instructions on brew.sh."),
                PageGuideStep(
                    icon: .refresh, title: "Check again",
                    detail: "Come back here and Edith finds it automatically."),
            ],
            primary: PageAction(
                "Check again", icon: .refresh, identifier: "homebrew.check"
            ) {
                model.activate(kind: kind)
            },
            secondary: PageAction("Open brew.sh", icon: .external, identifier: "homebrew.site") {
                NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            },
            footnote: "Edith never downloads or runs an installer on your behalf.")
    }

    private var summary: some View {
        WrapHStack(spacing: UIScale.pt(16), lineSpacing: UIScale.pt(6)) {
            Label(
                model.mode == .installed
                    ? "\(model.packages.count) installed \(model.packages.count == 1 ? kind.title.lowercased() : kind.pluralTitle.lowercased())"
                    : "\(model.packages.count) \(model.packages.count == 1 ? "result" : "results")",
                edith: kind == .formula ? .terminal : .selection)
            if model.mode == .installed {
                Label(
                    model.updateCount == 0
                        ? "Everything up to date"
                        : "\(model.updateCount) \(model.updateCount == 1 ? "update" : "updates") available",
                    edith: model.updateCount == 0 ? .success : .arrowUp
                )
                .foregroundStyle(
                    model.updateCount == 0
                        ? AnyShapeStyle(.secondary) : AnyShapeStyle(DashSkin.warn))
            }
            if let version = model.status?.version {
                Label(version, edith: .box)
            }
        }
        .font(.edithText(.caption))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .help(
            kind == .formula
                ? "Formulae are command line tools and libraries." : "Casks are Mac apps.")
    }

    @ViewBuilder
    private var operationCard: some View {
        if model.isBusy || model.errorMessage != nil || model.resultMessage != nil {
            HomebrewCard {
                HStack(alignment: .center, spacing: UIScale.pt(12)) {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        EdithIconView(model.errorMessage == nil ? .success : .warning)
                            .foregroundStyle(model.errorMessage == nil ? DashSkin.sage : .red)
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Text(
                            model.operationTitle ?? model.resultMessage
                                ?? "Homebrew could not finish"
                        )
                        .font(.edithText(.headline))
                        if let error = model.errorMessage {
                            Text(error)
                                .font(.edithText(.callout))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !model.output.isEmpty {
                            Text(model.output)
                                .font(.edithText(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(8)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.isBusy {
                        Button(model.isCancelling ? "Cancelling…" : "Cancel") { model.cancel() }
                            .buttonStyle(.edith(.secondary))
                            .disabled(model.isCancelling)
                    } else {
                        Button("Dismiss") { model.clearNotice() }
                            .buttonStyle(.edith(.secondary))
                    }
                }
            }
        }
    }

    private var visiblePackages: [HomebrewPackage] {
        guard model.mode == .installed else { return model.packages }
        let query = model.installedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.packages.filter {
            (!model.updatesOnly || $0.outdated)
                && (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
                    || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.description?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    private var packageCard: some View {
        let packages = visiblePackages
        return HomebrewPackageTable(
            packages: packages,
            disabled: model.isBusy, accent: theme,
            perform: { action, package in
                if action == .uninstall {
                    pendingUninstall = package
                } else {
                    model.perform(action, package: package, query: model.query, kind: kind)
                }
            }
        )
    }

    private var listingState: HomebrewListingState {
        HomebrewListingState(
            available: model.status?.available, mode: model.mode,
            hasQuery: !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            filtersActive: !model.installedQuery.isEmpty || model.updatesOnly,
            hasPackages: !visiblePackages.isEmpty)
    }

    @ViewBuilder private var listingEmptyState: some View {
        switch listingState {
        case .discoverPrompt:
            PageEmptyState(
                icon: .search,
                title: "Find software to install",
                message:
                    "Type a name or keyword above, like ripgrep or firefox, then press Search. You can look at a package before installing it.",
                footnote: "Switch Package to Casks to find Mac apps instead of command line tools.")
        case .noSearchResults:
            PageEmptyState(
                icon: .help,
                title: "No \(kind.pluralTitle.lowercased()) found",
                message:
                    "Nothing matched \"\(model.query.trimmingCharacters(in: .whitespacesAndNewlines))\". Check the spelling, try a shorter keyword, or switch between Formulae and Casks."
            )
        case .nothingInstalled:
            PageEmptyState(
                icon: .box,
                title: "No \(kind.pluralTitle.lowercased()) installed yet",
                message:
                    "Packages you install with Homebrew show up here, along with any updates. Browse what is available to install your first one.",
                primary: PageAction(
                    "Discover packages", icon: .search,
                    identifier: "homebrew.discover"
                ) {
                    model.mode = .search
                })
        case .noMatchingFilters:
            PageEmptyState(
                icon: .filter,
                title: "No packages match these filters",
                message: "Clear the search or the Updates filter to see everything installed.",
                primary: PageAction("Clear filters", identifier: "homebrew.clear") {
                    model.installedQuery = ""
                    model.updatesOnly = false
                })
        case .notInstalled, .packages:
            EmptyView()
        }
    }

    private func runSearch() {
        let value = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.search(value, kind: kind)
    }

    private func refreshCurrentMode() {
        if model.mode == .installed {
            model.loadInstalled(kind: kind)
        } else if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runSearch()
        } else {
            model.packages = []
            model.loading.setContent()
        }
    }
}

struct HomebrewPackageTable: View {
    static let versionWidth = 190.0
    static let actionsWidth = 170.0
    let packages: [HomebrewPackage]
    @State private var columns = TableColumnCustomization<HomebrewPackage>()
    let disabled: Bool
    let accent: Color
    let perform: (HomebrewMutation, HomebrewPackage) -> Void
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Table(packages, columnCustomization: $columns) {
            SwiftUI.TableColumn("Package") { package in
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(package.displayName).font(.edithText(.body)).lineLimit(1)
                    if let subtitle = package.subtitle {
                        Text(subtitle).font(.edithText(.caption))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    if compact {
                        Text(package.versionSummary).font(.edithText(.caption2))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help("\(package.name)\n\(package.subtitle ?? "")\n\(package.versionSummary)")
            }
            .width(min: UIScale.pt(PageMetrics.tableNameMinimumWidth), max: .infinity)
            SwiftUI.TableColumn("Version") { Text($0.versionSummary).monospacedDigit() }
                .width(UIScale.pt(Self.versionWidth))
                .customizationID("version")
                .defaultVisibility(compact ? .hidden : .visible)
            SwiftUI.TableColumn("Status") { package in
                Text(
                    package.outdated ? "Update" : package.installed ? "Installed" : "Available"
                )
                .foregroundStyle(package.outdated ? DashSkin.warn : .secondary)
            }
            .width(UIScale.pt(80))
            SwiftUI.TableColumn(compact ? "" : "Actions") { package in
                if compact {
                    Menu {
                        packageActions(package)
                    } label: {
                        EdithIcon.more.image()
                    }
                    .borderlessMenu().menuIndicator(.hidden)
                    .accessibilityLabel("Actions for \(package.displayName)")
                    .disabled(disabled)
                } else {
                    HStack(spacing: UIScale.pt(8)) {
                        if package.installed, !package.outdated {
                            upgradeButton(package).hidden()
                        }
                        packageActions(package)
                    }
                    .fixedSize()
                    .disabled(disabled)
                }
            }
            .width(UIScale.pt(compact ? 44 : Self.actionsWidth))
        }
        .themedSelection()
        .font(.edithText(.callout))
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(10), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(10), style: .continuous)
                .strokeBorder(DashSkin.line(scheme == .dark))
                .allowsHitTesting(false)
        }
        .accessibilityLabel("Homebrew packages")
        .onChange(of: compact, initial: true) { _, compact in
            columns[visibility: "version"] = compact ? .hidden : .visible
        }
    }

    @ViewBuilder
    private func packageActions(_ package: HomebrewPackage) -> some View {
        if package.installed {
            if package.outdated { upgradeButton(package) }
            Button("Uninstall", role: .destructive) { perform(.uninstall, package) }
                .buttonStyle(.edith(.borderless))
                .foregroundStyle(DashSkin.danger)
        } else {
            Button("Install") { perform(.install, package) }
                .buttonStyle(.edith(.primary, tint: accent))
        }
    }

    private func upgradeButton(_ package: HomebrewPackage) -> some View {
        Button("Upgrade") { perform(.upgrade, package) }
            .buttonStyle(.edith(.secondary, tint: accent))
    }
}

private struct HomebrewCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(UIScale.pt(16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .edithSurface(cornerRadius: 14)
    }
}
