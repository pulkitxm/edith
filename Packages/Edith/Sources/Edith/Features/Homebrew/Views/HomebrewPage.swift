import EdithKit
import SwiftUI

struct HomebrewMaintenanceView: View {
    @State private var model: HomebrewPageModel
    @State private var query = ""
    @State private var pendingUninstall: HomebrewPackage?
    @AppStorage(AppStorageKeys.Homebrew.defaultKind, store: SharedDefaults.store)
    private var kindRaw = HomebrewPackageKind.formula.rawValue
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = AppTheme.accent.rawValue
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    @MainActor
    init() {
        _model = State(initialValue: HomebrewPageModel())
    }

    @MainActor
    init(model: HomebrewPageModel) {
        _model = State(initialValue: model)
    }

    private var kind: HomebrewPackageKind {
        HomebrewPackageKind(rawValue: kindRaw) ?? .formula
    }

    private var theme: Color { themeColor(themeName) }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            if showsLoadingSkeleton {
                HomebrewPageSkeleton()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.status?.available == false {
                            unavailableCard
                        } else {
                            summary
                            operationCard
                            packageCard
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(DashSkin.paper(scheme == .dark))
        .task {
            guard automaticActionsEnabled else { return }
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
            } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.search(query, kind: kind)
            } else {
                model.packages = []
                model.loaded = true
            }
        }
        .onDisappear { model.cancel() }
        .confirmationDialog(
            "Uninstall \(pendingUninstall?.displayName ?? "package")?",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } })
        ) {
            Button("Uninstall", role: .destructive) {
                guard let package = pendingUninstall else { return }
                pendingUninstall = nil
                model.perform(.uninstall, package: package, query: query, kind: kind)
            }
            Button("Cancel", role: .cancel) { pendingUninstall = nil }
        } message: {
            Text(
                "Homebrew will remove this \(pendingUninstall?.kind.rawValue ?? "package") and its managed files."
            )
        }
    }

    private var showsLoadingSkeleton: Bool {
        !model.loaded && model.packages.isEmpty && model.errorMessage == nil
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
                    .frame(width: 52, alignment: .leading)
                kindPicker
            }
            HStack(spacing: 8) {
                filterLabel("View")
                    .frame(width: 52, alignment: .leading)
                modePicker
            }
        }
    }

    private func filterLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var kindPicker: some View {
        Picker("Package kind", selection: $kindRaw) {
            ForEach(HomebrewPackageKind.allCases) { kind in
                Text(kind.pluralTitle).tag(kind.rawValue)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 190)
        .disabled(model.isBusy)
    }

    private var modePicker: some View {
        Picker("View", selection: $model.mode) {
            ForEach(HomebrewPageMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 170)
    }

    @ViewBuilder
    private var actions: some View {
        if model.mode == .search {
            HStack(spacing: 10) {
                SearchField(placeholder: "Search \(kind.pluralTitle.lowercased())", text: $query)
                    .frame(maxWidth: compact ? .infinity : 320)
                    .onSubmit { runSearch() }
                Button("Search", action: runSearch)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.isBusy
                            || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } else {
            Button {
                model.loadInstalled(kind: kind)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)
        }
    }

    private var unavailableCard: some View {
        HomebrewCard {
            VStack(spacing: 16) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Homebrew is not installed")
                    .font(DashSkin.serif(24))
                Text(
                    "Edith never downloads or runs a package manager installer. Install Homebrew from its official site, then check again."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                HStack {
                    Link("Open brew.sh", destination: URL(string: "https://brew.sh")!)
                    Button("Check Again") { model.activate(kind: kind) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 42)
        }
    }

    private var summary: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: compact ? 150 : 190), spacing: 12)],
            spacing: 12
        ) {
            HomebrewMetric(
                title: model.mode == .installed ? "Installed" : "Results",
                value: String(
                    model.mode == .installed ? model.installedCount : model.packages.count),
                detail: kind.pluralTitle, icon: "shippingbox.fill", accent: theme)
            HomebrewMetric(
                title: "Updates", value: String(model.updateCount),
                detail: model.updateCount == 1 ? "package ready" : "packages ready",
                icon: "arrow.up.circle.fill", accent: theme)
            HomebrewMetric(
                title: "Homebrew",
                value: model.status?.available == true ? "Ready" : "Checking",
                detail: model.status?.version ?? model.status?.executable
                    ?? "Local package manager",
                icon: "checkmark.seal.fill", accent: theme)
        }
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
                        .font(.system(size: 13, weight: .semibold))
                        if let error = model.errorMessage {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !model.output.isEmpty {
                            Text(model.output)
                                .font(.system(size: 10.5, design: .monospaced))
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

    private var packageCard: some View {
        HomebrewCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(
                        model.mode == .installed
                            ? "Installed \(kind.pluralTitle)" : "Search Results"
                    )
                    .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(model.packages.count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 12)

                if model.packages.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: model.mode == .search ? "magnifyingglass" : "shippingbox")
                            .font(.system(size: 25))
                            .foregroundStyle(.tertiary)
                        Text(emptyTitle)
                            .font(.system(size: 14, weight: .semibold))
                        Text(emptyDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ForEach(Array(model.packages.enumerated()), id: \.element.id) {
                        index, package in
                        if index > 0 { Divider() }
                        HomebrewPackageRow(
                            package: package, disabled: model.isBusy, accent: theme,
                            perform: {
                                model.perform($0, package: package, query: query, kind: kind)
                            },
                            uninstall: { pendingUninstall = package })
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        if model.mode == .search, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search Homebrew"
        }
        return model.mode == .search
            ? "No packages found" : "No installed \(kind.pluralTitle.lowercased())"
    }

    private var emptyDetail: String {
        if model.mode == .search, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a name or keyword to inspect available packages before installing."
        }
        return model.mode == .search
            ? "Try a different name or switch package kinds."
            : "Switch to Discover to find a package to install."
    }

    private func runSearch() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.search(value, kind: kind)
    }

    private func refreshCurrentMode() {
        if model.mode == .installed {
            model.loadInstalled(kind: kind)
        } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runSearch()
        } else {
            model.packages = []
            model.loaded = true
        }
    }
}

struct HomebrewPageSkeleton: View {
    @Environment(\.compactLayout) private var compact

    var body: some View {
        SkeletonGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: compact ? 150 : 190), spacing: 12)
                        ],
                        spacing: 12
                    ) {
                        ForEach(0..<3, id: \.self) { index in
                            HomebrewSkeletonCard {
                                HStack(spacing: 12) {
                                    SkeletonBlock(width: 32, height: 32, corner: 8)
                                    VStack(alignment: .leading, spacing: 5) {
                                        SkeletonBlock(width: 62, height: 8)
                                        SkeletonBlock(
                                            width: index == 2 ? 92 : 48,
                                            height: 17)
                                        SkeletonBlock(width: 112, height: 8)
                                    }
                                }
                            }
                        }
                    }
                    HomebrewSkeletonCard {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                SkeletonBlock(width: 164, height: 12)
                                Spacer()
                                SkeletonBlock(width: 26, height: 10)
                            }
                            .padding(.bottom, 12)
                            ForEach(0..<7, id: \.self) { index in
                                if index > 0 { Divider() }
                                HStack(spacing: 14) {
                                    SkeletonBlock(width: 38, height: 38, corner: 9)
                                    VStack(alignment: .leading, spacing: 5) {
                                        SkeletonBlock(
                                            width: index.isMultiple(of: 2) ? 118 : 152,
                                            height: 10)
                                        SkeletonBlock(width: 236, height: 8)
                                        SkeletonBlock(width: 84, height: 8)
                                    }
                                    Spacer(minLength: 8)
                                    SkeletonBlock(width: 72, height: 28, corner: 7)
                                }
                                .padding(.vertical, 11)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading Homebrew packages")
    }
}

private struct HomebrewSkeletonCard<Content: View>: View {
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

private struct HomebrewPackageRow: View {
    let package: HomebrewPackage
    let disabled: Bool
    let accent: Color
    let perform: (HomebrewMutation) -> Void
    let uninstall: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(accent.opacity(0.12))
                Image(systemName: package.kind == .cask ? "app.fill" : "terminal.fill")
                    .foregroundStyle(accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(package.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if package.outdated {
                        Text("UPDATE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.13), in: Capsule())
                    }
                }
                Text(package.description ?? package.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(package.versionSummary)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if package.installed {
                if package.outdated {
                    Button("Upgrade") { perform(.upgrade) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Uninstall", role: .destructive, action: uninstall)
            } else {
                Button("Install") { perform(.install) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 11)
        .disabled(disabled)
    }
}

private struct HomebrewMetric: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let accent: Color

    var body: some View {
        HomebrewCard {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(value)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
