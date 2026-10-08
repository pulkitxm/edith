import EdithKit
import SwiftUI

struct HomebrewMaintenanceView: View {
    @State private var model: HomebrewPageModel
    @State private var pendingUninstall: HomebrewPackage?
    @AppStorage(AppStorageKeys.Homebrew.defaultKind, store: SharedDefaults.store)
    private var kindRaw = HomebrewPackageKind.formula.rawValue
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = AppTheme.accent.rawValue
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    @MainActor
    init(model: HomebrewPageModel? = nil) {
        _model = State(initialValue: model ?? HomebrewPageModel())
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
        .pageTask(cancel: model.cancelDiscovery) {
            model.activate(kind: kind)
        }
        .onChange(of: kindRaw) { _, _ in
            guard automaticActionsEnabled else { return }
            refreshCurrentMode()
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
            "Uninstall \(pendingUninstall?.displayName ?? "package")?",
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
            Text(
                "Homebrew will remove this \(pendingUninstall?.kind.rawValue ?? "package") and its managed files."
            )
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
            "Package kind", selection: $kindRaw,
            options: HomebrewPackageKind.allCases.map(\.rawValue),
            label: { HomebrewPackageKind(rawValue: $0)?.pluralTitle ?? $0 }
        )
        .labelsHidden()
        .frame(width: UIScale.pt(190))
        .disabled(model.isBusy)
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
                            || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } else {
            HStack(spacing: UIScale.pt(8)) {
                SearchField(placeholder: "Filter installed packages", text: $model.installedQuery)
                    .frame(maxWidth: compact ? .infinity : UIScale.pt(300))
                Toggle("Updates", isOn: $model.updatesOnly)
                    .toggleStyle(.button)
                    .help("Show packages with an available update")
                Button {
                    model.loadInstalled(kind: kind)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.edith(.iconOnly))
                .accessibilityLabel("Refresh installed packages")
                .disabled(model.isBusy)
            }
        }
    }

    private var unavailableCard: some View {
        HomebrewCard {
            VStack(spacing: 16) {
                Image(systemName: "shippingbox")
                    .font(.system(size: UIScale.pt(34), weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Homebrew is not installed")
                    .font(DashSkin.heading(24))
                Text(
                    "Edith never downloads or runs a package manager installer. Install Homebrew from its official site, then check again."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: UIScale.pt(520))
                HStack {
                    Link("Open brew.sh", destination: URL(string: "https://brew.sh")!)
                    Button("Check Again") { model.activate(kind: kind) }
                        .buttonStyle(.edith(.primary))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 42)
        }
    }

    private var summary: some View {
        WrapHStack(spacing: UIScale.pt(14), lineSpacing: UIScale.pt(6)) {
            Label(
                "\(model.packages.count) \(kind.pluralTitle.lowercased())",
                systemImage: "shippingbox")
            Label("\(model.updateCount) updates", systemImage: "arrow.up.circle")
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
            if packages.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "shippingbox")
                } description: {
                    Text(emptyDetail)
                } actions: {
                    if model.mode == .installed,
                        !model.installedQuery.isEmpty || model.updatesOnly
                    {
                        Button("Clear filters") {
                            model.installedQuery = ""
                            model.updatesOnly = false
                        }
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        if model.mode == .installed, !model.installedQuery.isEmpty || model.updatesOnly {
            return "No packages match these filters"
        }
        if model.mode == .search,
            model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "Search Homebrew"
        }
        return model.mode == .search
            ? "No packages found" : "No installed \(kind.pluralTitle.lowercased())"
    }

    private var emptyDetail: String {
        if model.mode == .installed, !model.installedQuery.isEmpty || model.updatesOnly {
            return "Clear the search or Updates filter to see all installed packages."
        }
        if model.mode == .search,
            model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "Enter a name or keyword to inspect available packages before installing."
        }
        return model.mode == .search
            ? "Try a different name or switch package kinds."
            : "Switch to Discover to find a package to install."
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
    let packages: [HomebrewPackage]
    @Binding var selection: String?
    @State private var columns = TableColumnCustomization<HomebrewPackage>()
    let disabled: Bool
    let accent: Color
    let perform: (HomebrewMutation, HomebrewPackage) -> Void
    @Environment(\.compactLayout) private var compact

    var body: some View {
        GeometryReader { geometry in
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
                .width(
                    PageMetrics.tableNameWidth(
                        viewport: geometry.size.width,
                        fixedWidth: (compact ? 0 : 140) + 80 + (compact ? 44 : 220),
                        columnCount: compact ? 3 : 4))
                SwiftUI.TableColumn("Version") { Text($0.versionSummary).monospacedDigit() }
                    .width(UIScale.pt(140))
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
                .width(UIScale.pt(compact ? 44 : 220))
            }
            .font(.edithText(.callout))
            .accessibilityLabel("Homebrew packages")
            .onChange(of: compact, initial: true) { _, compact in
                columns[visibility: "version"] = compact ? .hidden : .visible
            }
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
