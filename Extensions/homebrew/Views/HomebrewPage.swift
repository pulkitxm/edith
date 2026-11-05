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
            filterBar
                .pageGutter(compact)
                .padding(.vertical, 12)
            if model.status?.available != false {
                summary.pageGutter(compact).padding(.bottom, UIScale.pt(8))
                operationCard.pageGutter(compact).padding(.bottom, UIScale.pt(8))
            }
            Divider()
        } content: {
            PageLoading(
                state: model.loading.state,
                message: model.errorMessage ?? "Homebrew could not load its packages.",
                layout: .editor, refreshing: model.loading.isRefreshing,
                retry: refreshCurrentMode
            ) {
                if model.status?.available == false {
                    unavailableCard
                } else {
                    packageCard
                }
            }
            .pageGutter(compact)
            .padding(.vertical, UIScale.pt(12))
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
            HStack(spacing: 20) {
                filters
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                actions
            }
            VStack(alignment: .leading, spacing: 10) {
                compactFilters
                actions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                filterLabel("Package")
                kindPicker
            }
            HStack(spacing: 8) {
                filterLabel("View")
                modePicker
            }
        }
    }

    private var compactFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                filterLabel("Package")
                    .frame(width: UIScale.pt(52), alignment: .leading)
                kindPicker
            }
            HStack(spacing: 8) {
                filterLabel("View")
                    .frame(width: UIScale.pt(52), alignment: .leading)
                modePicker
            }
        }
    }

    private func filterLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: UIScale.pt(11), weight: .semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
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
            HStack(spacing: 10) {
                SearchField(
                    placeholder: "Search \(kind.pluralTitle.lowercased())", text: $model.query
                )
                .frame(maxWidth: compact ? .infinity : 320)
                .onSubmit { runSearch() }
                Button("Search", action: runSearch)
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
                Toggle("Updates only", isOn: $model.updatesOnly)
                    .toggleStyle(.button)
                    .help("Show only packages with a newer version available")
                Button {
                    model.loadInstalled(kind: kind)
                } label: {
                    Image(systemName: "arrow.clockwise")
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
            symbolName: "shippingbox",
            title: "Homebrew is not installed",
            message:
                "Homebrew is a free package manager that installs command line tools and Mac apps. Edith manages it for you once it is on this Mac.",
            steps: [
                PageGuideStep(
                    symbolName: "safari", title: "Get Homebrew",
                    detail: "Follow the install instructions on brew.sh."),
                PageGuideStep(
                    symbolName: "arrow.clockwise", title: "Check again",
                    detail: "Come back here and Edith finds it automatically."),
            ],
            primary: PageAction(
                "Check again", symbolName: "arrow.clockwise", identifier: "homebrew.check"
            ) {
                model.activate(kind: kind)
            },
            secondary: PageAction("Open brew.sh", symbolName: "safari", identifier: "homebrew.site")
            {
                NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            },
            footnote: "Edith never downloads or runs an installer on your behalf.")
    }

    private var summary: some View {
        WrapHStack(spacing: UIScale.pt(14), lineSpacing: UIScale.pt(6)) {
            Label(
                model.mode == .installed
                    ? "\(model.packages.count) installed \(kind.pluralTitle.lowercased())"
                    : "\(model.packages.count) results",
                systemImage: "shippingbox")
            Text(
                kind == .formula
                    ? "Formulae are command line tools and libraries." : "Casks are Mac apps.")
            Label(
                model.updateCount == 0
                    ? "Everything up to date"
                    : "\(model.updateCount) \(model.updateCount == 1 ? "update" : "updates") available",
                systemImage: model.updateCount == 0 ? "checkmark.circle" : "arrow.up.circle")
            if let version = model.status?.version { Text(version) }
        }
        .font(.edithText(.caption))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var operationCard: some View {
        if model.isBusy || model.errorMessage != nil || model.resultMessage != nil {
            HomebrewCard {
                HStack(alignment: .top, spacing: 12) {
                    if model.isBusy {
                        SkeletonGroup {
                            SkeletonBlock(width: 16, height: 16, corner: 8)
                        }
                    } else {
                        Image(
                            systemName: model.errorMessage == nil
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(model.errorMessage == nil ? DashSkin.sage : .red)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(
                            model.operationTitle ?? model.resultMessage
                                ?? "Homebrew could not finish"
                        )
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                        if let error = model.errorMessage {
                            Text(error)
                                .font(.system(size: UIScale.pt(12)))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !model.output.isEmpty {
                            Text(model.output)
                                .font(.system(size: UIScale.pt(10.5), design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(8)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.isBusy {
                        Button(model.isCancelling ? "Cancelling" : "Cancel") { model.cancel() }
                            .disabled(model.isCancelling)
                    } else {
                        Button("Dismiss") { model.clearNotice() }
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
            packages: packages, selection: $model.selectedPackageID,
            disabled: model.isBusy, accent: theme,
            perform: { action, package in
                if action == .uninstall {
                    pendingUninstall = package
                } else {
                    model.perform(action, package: package, query: model.query, kind: kind)
                }
            }
        )
        .overlay {
            if listingState != .packages { listingEmptyState }
        }
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
                symbolName: "magnifyingglass",
                title: "Find software to install",
                message:
                    "Type a name or keyword above, like ripgrep or firefox, then press Search. You can look at a package before installing it.",
                footnote: "Switch Package to Casks to find Mac apps instead of command line tools.")
        case .noSearchResults:
            PageEmptyState(
                symbolName: "questionmark.circle",
                title: "No \(kind.pluralTitle.lowercased()) found",
                message:
                    "Nothing matched \"\(model.query.trimmingCharacters(in: .whitespacesAndNewlines))\". Check the spelling, try a shorter keyword, or switch between Formulae and Casks."
            )
        case .nothingInstalled:
            PageEmptyState(
                symbolName: "shippingbox",
                title: "No \(kind.pluralTitle.lowercased()) installed yet",
                message:
                    "Packages you install with Homebrew show up here, along with any updates. Browse what is available to install your first one.",
                primary: PageAction(
                    "Discover packages", symbolName: "magnifyingglass",
                    identifier: "homebrew.discover"
                ) {
                    model.mode = .search
                })
        case .noMatchingFilters:
            PageEmptyState(
                symbolName: "line.3.horizontal.decrease.circle",
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
    @Binding var selection: String?
    @State private var columns = TableColumnCustomization<HomebrewPackage>()
    let disabled: Bool
    let accent: Color
    let perform: (HomebrewMutation, HomebrewPackage) -> Void
    @Environment(\.compactLayout) private var compact

    var body: some View {
        Table(packages, selection: $selection, columnCustomization: $columns) {
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
            SwiftUI.TableColumn("Actions") { package in
                if compact {
                    Menu {
                        packageActions(package)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .accessibilityLabel("Actions for \(package.displayName)")
                    .disabled(disabled)
                } else {
                    HStack(spacing: UIScale.pt(8)) { packageActions(package) }.fixedSize()
                        .disabled(disabled)
                }
            }
            .width(UIScale.pt(compact ? 44 : Self.actionsWidth))
        }
        .font(.edithText(.callout))
        .accessibilityLabel("Homebrew packages")
        .onChange(of: compact, initial: true) { _, compact in
            columns[visibility: "version"] = compact ? .hidden : .visible
        }
    }

    @ViewBuilder
    private func packageActions(_ package: HomebrewPackage) -> some View {
        if package.installed {
            if package.outdated {
                Button("Upgrade") { perform(.upgrade, package) }
                    .buttonStyle(.edith(.secondary, tint: accent))
            }
            Button("Uninstall", role: .destructive) { perform(.uninstall, package) }
                .buttonStyle(.edith(.borderless, tint: DashSkin.danger))
        } else {
            Button("Install") { perform(.install, package) }
                .buttonStyle(.edith(.primary, tint: accent))
        }
    }
}

private struct HomebrewCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(16)
            .background(
                DashSkin.paper2(scheme == .dark),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(DashSkin.line(scheme == .dark))
            }
    }
}
