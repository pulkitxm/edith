import AppKit
import EdithKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
@Observable
final class AppMaintenanceModel {
    enum Phase: Equatable {
        case loading
        case ready
        case scanning
        case removing
        case mounting
        case installing
        case updating
    }

    var applications: [InstalledApplication] = []
    var selectedApplicationID: String?
    var plan: AppMaintenancePlan?
    var selectedItemIDs = Set<String>()
    var phase = Phase.loading
    var errorMessage: String?
    var resultMessage: String?
    var installPlan: AppMaintenanceDiskImagePlan?
    var updates: [AppUpdateItem] = []
    var updateHistory: [AppUpdateResult] = []
    var selectedUpdateIDs = Set<String>()
    var lastUpdateRefresh: Date?
    private var updateState = AppUpdateCenterState()
    private let updatePersistence = AppUpdatePersistence()
    private let updateExecutor = AppUpdateExecutor()
    private var task: Task<Void, Never>?
    private var securityScopedURL: URL?
    private var hasSecurityScopedAccess = false

    var selectedApplication: InstalledApplication? {
        applications.first { $0.id == selectedApplicationID }
    }

    var selectedItems: [AppMaintenanceItem] {
        guard let plan else { return [] }
        var selected: [AppMaintenanceItem] = []
        selected.reserveCapacity(plan.items.count)
        for item in plan.items where selectedItemIDs.contains(item.id) {
            selected.append(item)
        }
        return selected
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }

    func refresh(automatic: Bool = false) {
        task?.cancel()
        phase = .loading
        errorMessage = nil
        resultMessage = nil
        task = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                let applications = AppMaintenanceInventory.applications(updateData: Data())
                let updates = await AppUpdateDiscovery.discover(applications: applications)
                return (applications, updates)
            }.value
            guard !Task.isCancelled else { return }
            var previousIDs: Set<String> = []
            for update in updates { previousIDs.insert(update.id) }
            updateState = updatePersistence.load()
            updateState.lastRefresh = Date()
            do {
                try updatePersistence.save(updateState)
            } catch {
                errorMessage = error.localizedDescription
            }
            applications = loaded.0
            updates = updatePersistence.visible(
                loaded.1, state: updateState, now: updateState.lastRefresh ?? Date())
            updateHistory = updateState.history
            lastUpdateRefresh = updateState.lastRefresh
            var visibleIDs: Set<String> = []
            for update in updates { visibleIDs.insert(update.id) }
            selectedUpdateIDs.formIntersection(visibleIDs)
            if selectedUpdateIDs.isEmpty { selectedUpdateIDs = visibleIDs }
            phase = .ready
            if let selectedApplicationID,
                !loaded.0.contains(where: { $0.id == selectedApplicationID })
            {
                self.selectedApplicationID = nil
                plan = nil
                selectedItemIDs = []
            }
            if automatic {
                var freshCount = 0
                for update in updates where !previousIDs.contains(update.id) { freshCount += 1 }
                if freshCount > 0 { await notify(updateCount: freshCount) }
            }
        }
    }

    func setUpdateSelected(_ selected: Bool, item: AppUpdateItem) {
        if selected {
            selectedUpdateIDs.insert(item.id)
        } else {
            selectedUpdateIDs.remove(item.id)
        }
    }

    func runSelectedUpdates(concurrency: Int, retries: Int) {
        let selected = updates.filter { selectedUpdateIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        task?.cancel()
        phase = .updating
        errorMessage = nil
        resultMessage = nil
        task = Task {
            do {
                let results = try await updateExecutor.execute(
                    AppUpdatePlan(items: selected, concurrency: concurrency, retries: retries),
                    confirmed: true)
                guard !Task.isCancelled else { return }
                updateState = updatePersistence.recording(results, in: updateState)
                try updatePersistence.save(updateState)
                updateHistory = updateState.history
                let succeeded = results.filter { $0.status == .succeeded }.count
                resultMessage = "Finished \(succeeded) of \(results.count) updates."
                phase = .ready
                refresh()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func ignore(_ item: AppUpdateItem) {
        updateState.ignoredVersions[item.id] = item.availableVersion
        persistPolicy(removing: item)
    }

    func snooze(_ item: AppUpdateItem, until: Date) {
        updateState.snoozedUntil[item.id] = until
        persistPolicy(removing: item)
    }

    func exclude(_ item: AppUpdateItem) {
        guard let bundleID = item.bundleID else { return }
        updateState.excludedBundleIDs.insert(bundleID)
        persistPolicy(removing: item)
    }

    func resetUpdatePolicies() {
        updateState.ignoredVersions = [:]
        updateState.snoozedUntil = [:]
        updateState.excludedBundleIDs = []
        do {
            try updatePersistence.save(updateState)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistPolicy(removing item: AppUpdateItem) {
        do {
            try updatePersistence.save(updateState)
            updates.removeAll { $0.id == item.id }
            selectedUpdateIDs.remove(item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func notify(updateCount: Int) async {
        guard
            SharedDefaults.store.bool(
                forKey: AppStorageKeys.AppMaintenance.updateNotifications)
        else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "App Update Center"
        content.body = "\(updateCount) new updates are available."
        try? await center.add(
            UNNotificationRequest(
                identifier: "app-update-center", content: content, trigger: nil))
    }

    func select(_ application: InstalledApplication) {
        task?.cancel()
        selectedApplicationID = application.id
        plan = nil
        selectedItemIDs = []
        errorMessage = nil
        resultMessage = nil
        phase = .scanning
        task = Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try AppMaintenanceExecution.plan(applicationURL: application.url)
                }.value
                guard !Task.isCancelled, selectedApplicationID == application.id else { return }
                plan = loaded
                selectedItemIDs = Set(loaded.items.map(\.id))
                phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func setSelected(_ selected: Bool, item: AppMaintenanceItem) {
        if selected {
            selectedItemIDs.insert(item.id)
        } else {
            selectedItemIDs.remove(item.id)
        }
    }

    func removeSelected() {
        guard let plan else { return }
        let selectedIDs = selectedItemIDs
        task?.cancel()
        phase = .removing
        errorMessage = nil
        resultMessage = nil
        task = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try AppMaintenanceExecution.remove(plan: plan, selectedIDs: selectedIDs)
                }.value
                guard !Task.isCancelled else { return }
                if result.failed.isEmpty {
                    resultMessage =
                        "Moved \(result.removed.count) items, \(JunkScanner.format(result.reclaimedBytes)), to the Trash."
                } else {
                    resultMessage =
                        "Moved \(result.removed.count) items to the Trash. \(result.failed.count) items could not be moved."
                }
                applications = await Task.detached(priority: .userInitiated) {
                    await AppMaintenanceInventory.applicationsWithUpdates()
                }.value
                selectedApplicationID = nil
                self.plan = nil
                selectedItemIDs = []
                phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func prepareDiskImage(_ url: URL, destination: AppMaintenanceInstallDestination) {
        task?.cancel()
        cancelInstallPlan()
        phase = .mounting
        errorMessage = nil
        resultMessage = nil
        task = Task {
            let accessing = url.startAccessingSecurityScopedResource()
            var retainedAccess = false
            defer {
                if accessing, !retainedAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let prepared = try await AppMaintenanceDiskImageInstaller.plan(
                    imageURL: url, destination: destination)
                guard !Task.isCancelled else {
                    await AppMaintenanceDiskImageInstaller.cancel(plan: prepared)
                    return
                }
                securityScopedURL = url
                hasSecurityScopedAccess = accessing
                retainedAccess = true
                installPlan = prepared
                phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func installDiskImage(replaceExisting: Bool, moveImageToTrash: Bool) {
        guard let installPlan else { return }
        task?.cancel()
        phase = .installing
        errorMessage = nil
        resultMessage = nil
        task = Task {
            defer { releaseSecurityScopedAccess() }
            do {
                let result = try await AppMaintenanceDiskImageInstaller.install(
                    plan: installPlan, replaceExisting: replaceExisting,
                    moveImageToTrash: moveImageToTrash)
                guard !Task.isCancelled else { return }
                self.installPlan = nil
                applications = await Task.detached(priority: .userInitiated) {
                    await AppMaintenanceInventory.applicationsWithUpdates()
                }.value
                let cleanup: String
                if !result.ejected {
                    cleanup = " The disk image is still mounted."
                } else if moveImageToTrash, !result.imageMovedToTrash {
                    cleanup = " The disk image was kept."
                } else {
                    cleanup = ""
                }
                resultMessage = "Installed \(result.applicationURL.lastPathComponent).\(cleanup)"
                phase = .ready
            } catch {
                self.installPlan = nil
                guard !Task.isCancelled else {
                    phase = .ready
                    return
                }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func cancelInstallPlan() {
        if let installPlan {
            self.installPlan = nil
            Task { await AppMaintenanceDiskImageInstaller.cancel(plan: installPlan) }
        }
        releaseSecurityScopedAccess()
    }

    func cancel() {
        task?.cancel()
        task = nil
        Task { await updateExecutor.cancel() }
        if phase != .installing { cancelInstallPlan() }
    }

    private func releaseSecurityScopedAccess() {
        if hasSecurityScopedAccess { securityScopedURL?.stopAccessingSecurityScopedResource() }
        securityScopedURL = nil
        hasSecurityScopedAccess = false
    }
}

enum AppMaintenanceSection: String, CaseIterable, Identifiable {
    case updates = "Updates"
    case packages = "Packages"
    case removal = "Remove"
    case history = "History"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .updates: "arrow.up.circle"
        case .packages: "shippingbox"
        case .removal: "trash"
        case .history: "clock.arrow.circlepath"
        }
    }

    var summary: String {
        switch self {
        case .updates: "Review and run available application updates."
        case .packages: "Manage installed and discoverable Homebrew packages."
        case .removal: "Review applications and their related files before removal."
        case .history: "Review completed maintenance operations."
        }
    }
}

struct AppMaintenanceView: View {
    @State private var model = AppMaintenanceModel()
    @State private var query = ""
    @State private var confirmingRemoval = false
    @State private var confirmingUpdates = false
    @State private var showingDiskImagePicker = false
    @State private var showingUpdateSettings = false
    @AppStorage(AppStorageKeys.AppMaintenance.section, store: SharedDefaults.store)
    private var sectionRaw = AppMaintenanceSection.updates.rawValue
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @AppStorage(AppStorageKeys.AppMaintenance.installDestination, store: SharedDefaults.store)
    private var installDestinationRaw = AppMaintenanceInstallDestination.user.rawValue
    @AppStorage(AppStorageKeys.AppMaintenance.updateAutoRefresh, store: SharedDefaults.store)
    private var updateAutoRefresh = false
    @AppStorage(AppStorageKeys.AppMaintenance.updateNotifications, store: SharedDefaults.store)
    private var updateNotifications = true
    @AppStorage(AppStorageKeys.AppMaintenance.updateRefreshInterval, store: SharedDefaults.store)
    private var updateRefreshInterval = 86_400.0
    @AppStorage(AppStorageKeys.AppMaintenance.updateConcurrency, store: SharedDefaults.store)
    private var updateConcurrency = 2
    @AppStorage(AppStorageKeys.AppMaintenance.updateRetries, store: SharedDefaults.store)
    private var updateRetries = 1

    private var filteredApplications: [InstalledApplication] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return model.applications }
        return model.applications.filter {
            $0.name.localizedCaseInsensitiveContains(value)
                || $0.bundleID.localizedCaseInsensitiveContains(value)
        }
    }

    private var filteredUpdates: [AppUpdateItem] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return model.updates }
        return model.updates.filter {
            $0.name.localizedCaseInsensitiveContains(value)
                || $0.source.title.localizedCaseInsensitiveContains(value)
                || $0.bundleID?.localizedCaseInsensitiveContains(value) == true
        }
    }

    private var theme: Color { themeColor(themeName) }

    private var section: AppMaintenanceSection {
        AppMaintenanceSection(rawValue: sectionRaw) ?? .updates
    }

    private var sectionBinding: Binding<AppMaintenanceSection> {
        Binding(
            get: { section },
            set: { sectionRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: UIScale.pt(700), minHeight: UIScale.pt(520))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { model.refresh() }
        .task(id: updateAutoRefresh) {
            guard updateAutoRefresh else { return }
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(max(updateRefreshInterval, 900)))
                guard !Task.isCancelled else { return }
                model.refresh(automatic: true)
            }
        }
        .onDisappear { model.cancel() }
        .fileImporter(
            isPresented: $showingDiskImagePicker,
            allowedContentTypes: [UTType(filenameExtension: "dmg") ?? .data]
        ) { result in
            guard case .success(let url) = result else { return }
            model.prepareDiskImage(url, destination: installDestination)
        }
        .sheet(item: installPlanBinding) { plan in
            AppMaintenanceInstallReview(
                plan: plan, installing: model.phase == .installing,
                onCancel: { model.cancelInstallPlan() },
                onInstall: { replaceExisting, moveImageToTrash in
                    model.installDiskImage(
                        replaceExisting: replaceExisting,
                        moveImageToTrash: moveImageToTrash)
                })
        }
        .alert("Move selected items to the Trash?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.removeSelected() }
        } message: {
            Text(
                "\(model.selectedItems.count) reviewed items use \(JunkScanner.format(model.selectedBytes)). You can restore them from the Trash until it is emptied."
            )
        }
        .alert("Run selected updates?", isPresented: $confirmingUpdates) {
            Button("Cancel", role: .cancel) {}
            Button("Run Updates") {
                model.runSelectedUpdates(
                    concurrency: updateConcurrency, retries: updateRetries)
            }
        } message: {
            Text(
                "\(model.selectedUpdateIDs.count) reviewed updates will run with up to \(updateConcurrency) at once. App-native updaters will open for you to finish."
            )
        }
    }

    private var header: some View {
        PageHeader(
            section.rawValue,
            trailing: {
                Picker("Section", selection: sectionBinding) {
                    ForEach(AppMaintenanceSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.symbol).tag(section)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("App Maintenance section")
            },
            accessory: {
                HStack(spacing: UIScale.pt(10)) {
                    Text(section.summary)
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if section != .packages {
                        Button {
                            showingUpdateSettings.toggle()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .help("Update settings")
                        .popover(isPresented: $showingUpdateSettings) { updateSettings }
                        Menu {
                            Picker("Destination", selection: $installDestinationRaw) {
                                ForEach(AppMaintenanceInstallDestination.allCases, id: \.rawValue) {
                                    destination in
                                    Text(destination.title).tag(destination.rawValue)
                                }
                            }
                        } label: {
                            Label(installDestination.title, systemImage: "folder")
                        }
                        Button {
                            showingDiskImagePicker = true
                        } label: {
                            Label("Install Disk Image", systemImage: "externaldrive.badge.plus")
                        }
                        .disabled(model.phase != .ready)
                        Button {
                            model.refresh()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.phase != .ready)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if section == .packages {
            HomebrewMaintenanceView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.phase == .loading {
            AppMaintenanceSectionSkeleton(section: section)
        } else {
            HSplitView {
                sectionInventory
                    .frame(
                        minWidth: 280, idealWidth: 320, maxWidth: 380,
                        maxHeight: .infinity)
                detail
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sectionInventory: some View {
        switch section {
        case .updates: updateInventory
        case .packages: EmptyView()
        case .removal: removalInventory
        case .history: historyInventory
        }
    }

    private var removalInventory: some View {
        VStack(spacing: 0) {
            TextField("Search applications", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(UIScale.pt(12))
            Divider()
            if model.phase == .loading, model.applications.isEmpty {
                ProgressView("Scanning Applications")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApplications.isEmpty {
                ContentUnavailableView(
                    "No applications", systemImage: "app.dashed",
                    description: Text("No installed app matches this search."))
            } else {
                List(filteredApplications) { application in
                    Button {
                        model.select(application)
                    } label: {
                        AppMaintenanceApplicationRow(application: application)
                    }
                    .buttonStyle(
                        EdithButtonStyle(
                            .selection,
                            selected: model.selectedApplicationID == application.id,
                            tint: theme)
                    )
                    .listRowBackground(Color.clear)
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack {
                Text("\(model.applications.count) applications")
                Spacer()
                let updates = model.applications.filter { $0.update != nil }.count
                if updates > 0 { Text("\(updates) updates") }
            }
            .settingsCaption()
            .padding(.horizontal, UIScale.pt(12))
            .frame(height: UIScale.pt(34))
        }
    }

    private var updateInventory: some View {
        VStack(spacing: 0) {
            TextField("Search updates", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(UIScale.pt(12))
            Divider()
            if model.phase == .loading, model.updates.isEmpty {
                ProgressView("Checking Update Sources")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredUpdates.isEmpty {
                ContentUnavailableView(
                    "No updates", systemImage: "checkmark.circle",
                    description: Text("Everything visible is current, ignored, or snoozed."))
            } else {
                List(filteredUpdates) { item in
                    HStack(spacing: UIScale.pt(9)) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { model.selectedUpdateIDs.contains(item.id) },
                                set: { model.setUpdateSelected($0, item: item) })
                        )
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        if let path = item.applicationPath {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable()
                                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                        } else {
                            Image(systemName: "shippingbox")
                                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                        }
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(item.name).lineLimit(1)
                            Text("\(item.currentVersion) → \(item.availableVersion)")
                                .settingsCaption()
                        }
                        Spacer(minLength: 0)
                        Text(item.source.title).settingsCaption().lineLimit(1)
                    }
                    .padding(.vertical, UIScale.pt(3))
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack {
                Text("\(model.updates.count) available")
                Spacer()
                Text("\(model.selectedUpdateIDs.count) selected")
            }
            .settingsCaption()
            .padding(.horizontal, UIScale.pt(12))
            .frame(height: UIScale.pt(34))
        }
    }

    private var historyInventory: some View {
        Group {
            if model.updateHistory.isEmpty {
                ContentUnavailableView(
                    "No Update History", systemImage: "clock",
                    description: Text("Completed update attempts will appear here."))
            } else {
                List(model.updateHistory, id: \.finishedAt) { result in
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        HStack {
                            Text(result.name).lineLimit(1)
                            Spacer()
                            Image(
                                systemName: result.status == .succeeded
                                    ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                            )
                            .foregroundStyle(result.status == .succeeded ? .green : .orange)
                        }
                        Text("\(result.version) · \(result.source.title)").settingsCaption()
                        Text(result.finishedAt, style: .relative).settingsCaption()
                    }
                    .padding(.vertical, UIScale.pt(4))
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var installDestination: AppMaintenanceInstallDestination {
        AppMaintenanceInstallDestination(rawValue: installDestinationRaw) ?? .user
    }

    private var installPlanBinding: Binding<AppMaintenanceDiskImagePlan?> {
        Binding(
            get: { model.installPlan },
            set: { value in
                if value == nil, model.installPlan != nil { model.cancelInstallPlan() }
            })
    }

    private var progressMessage: String {
        switch model.phase {
        case .removing: "Moving selected items"
        case .mounting: "Mounting and verifying disk image"
        case .updating: "Running reviewed updates"
        default: "Finding exact support files"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .updates: updateDetail
        case .packages: EmptyView()
        case .removal: removalDetail
        case .history: historyDetail
        }
    }

    @ViewBuilder
    private var removalDetail: some View {
        if model.phase == .scanning {
            AppMaintenanceRemovalSkeleton()
        } else if model.phase == .removing || model.phase == .mounting {
            VStack(spacing: UIScale.pt(12)) {
                ProgressView()
                    .controlSize(.large)
                Text(progressMessage)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let application = model.selectedApplication, let plan = model.plan {
            removalPlan(application: application, plan: plan)
        } else {
            VStack(spacing: UIScale.pt(14)) {
                Image(systemName: "checklist")
                    .font(.system(size: UIScale.pt(44), weight: .light))
                    .foregroundStyle(.secondary)
                Text("Choose an application")
                    .font(.headline)
                Text(
                    "Edith will show the app and exact bundle-identifier matches before anything moves."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: UIScale.pt(360))
                statusMessage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(UIScale.pt(28))
        }
    }

    @ViewBuilder
    private var updateDetail: some View {
        if model.phase == .updating {
            VStack(spacing: UIScale.pt(14)) {
                ProgressView().controlSize(.large)
                Text("Running reviewed updates").font(.headline)
                Text("Results are saved separately for every item.").foregroundStyle(.secondary)
                Button("Cancel") { model.cancel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let item = model.updates.first(where: { model.selectedUpdateIDs.contains($0.id) })
        {
            VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                HStack(spacing: UIScale.pt(14)) {
                    if let path = item.applicationPath {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: UIScale.pt(54), height: UIScale.pt(54))
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Text(item.name).font(.title3.weight(.semibold))
                        Text("\(item.currentVersion) → \(item.availableVersion)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: UIScale.pt(4)) {
                        Text(item.source.title).fontWeight(.medium)
                        Text("\(item.confidence.title) confidence").settingsCaption()
                    }
                }
                GroupBox("Release") {
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        if let title = item.releaseTitle { Text(title).fontWeight(.medium) }
                        Text(
                            item.releaseNotes ?? "Release notes are not available from this source."
                        )
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        if let releaseURL = item.releaseURL {
                            Link("Open release information", destination: releaseURL)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(UIScale.pt(6))
                }
                GroupBox("Reviewed action") {
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        Text(item.command).font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Text(
                            "Checked \(item.checkedAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .settingsCaption()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(UIScale.pt(6))
                }
                statusMessage
                Spacer()
                HStack {
                    Menu("More") {
                        Button("Copy Command") { copy(item.command) }
                        if let path = item.applicationPath {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: path)
                                ])
                            }
                        }
                        Button("Ignore \(item.availableVersion)") { model.ignore(item) }
                        Button("Snooze for One Day") {
                            model.snooze(item, until: Date().addingTimeInterval(86_400))
                        }
                        if item.bundleID != nil {
                            Button("Exclude This App") { model.exclude(item) }
                        }
                    }
                    Spacer()
                    Button(
                        item.action == .openUpdater && model.selectedUpdateIDs.count == 1
                            ? "Open App Updater" : "Run \(model.selectedUpdateIDs.count) Updates"
                    ) {
                        confirmingUpdates = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedUpdateIDs.isEmpty)
                }
            }
            .padding(UIScale.pt(22))
        } else {
            ContentUnavailableView(
                "Select an update", systemImage: "arrow.down.app",
                description: Text(
                    "Choose updates to review their source, command, and release information."))
        }
    }

    private var historyDetail: some View {
        VStack(spacing: UIScale.pt(14)) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: UIScale.pt(44), weight: .light))
                .foregroundStyle(.secondary)
            Text("Update History").font(.headline)
            Text("Each attempt records its source, version, retries, result, and finish time.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: UIScale.pt(380))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var updateSettings: some View {
        Form {
            Toggle("Automatic refresh", isOn: $updateAutoRefresh)
            Picker("Refresh", selection: $updateRefreshInterval) {
                Text("Hourly").tag(3_600.0)
                Text("Daily").tag(86_400.0)
                Text("Weekly").tag(604_800.0)
            }
            .disabled(!updateAutoRefresh)
            Toggle("Notifications", isOn: $updateNotifications)
            Stepper("Concurrency: \(updateConcurrency)", value: $updateConcurrency, in: 1...4)
            Stepper("Retries: \(updateRetries)", value: $updateRetries, in: 0...3)
            Button("Reset Ignored, Snoozed, and Excluded Apps") {
                model.resetUpdatePolicies()
            }
            if AppUpdateAutomationHook.isAvailable() {
                LabeledContent("Automation command", value: AppUpdateAutomationHook.refreshCommand)
            }
            Text("Automatic refresh only checks. Updates always require an explicit action.")
                .settingsCaption()
        }
        .formStyle(.grouped)
        .frame(width: UIScale.pt(360), height: UIScale.pt(300))
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func removalPlan(
        application: InstalledApplication, plan: AppMaintenancePlan
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(12)) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                    .resizable()
                    .frame(width: UIScale.pt(48), height: UIScale.pt(48))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(application.name)
                        .font(.system(size: UIScale.pt(17), weight: .semibold))
                    Text("\(application.bundleID) · \(application.version)")
                        .settingsCaption()
                    if let update = application.update {
                        Label(
                            "\(update.latestVersion) available through \(update.source)",
                            systemImage: "arrow.down.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.green)
                    }
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([application.url])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
            }
            .padding(UIScale.pt(18))
            Divider()
            List {
                ForEach(AppMaintenanceCategory.allCases, id: \.self) { category in
                    let items = plan.items.filter { $0.category == category }
                    if !items.isEmpty {
                        Section(category.rawValue) {
                            ForEach(items) { item in
                                AppMaintenanceItemRow(
                                    item: item,
                                    selected: Binding(
                                        get: { model.selectedItemIDs.contains(item.id) },
                                        set: { model.setSelected($0, item: item) }))
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            VStack(spacing: UIScale.pt(8)) {
                statusMessage
                HStack {
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text("\(model.selectedItems.count) of \(plan.items.count) selected")
                            .fontWeight(.medium)
                        Text(JunkScanner.format(model.selectedBytes))
                            .settingsCaption()
                    }
                    Spacer()
                    Button("Move to Trash", role: .destructive) {
                        confirmingRemoval = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.selectedItems.isEmpty)
                }
            }
            .padding(UIScale.pt(16))
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let message = model.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if let message = model.resultMessage {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }
}

struct AppMaintenanceSectionSkeleton: View {
    let section: AppMaintenanceSection

    var body: some View {
        SkeletonGroup {
            HSplitView {
                inventory
                    .frame(
                        minWidth: 280, idealWidth: 320, maxWidth: 380,
                        maxHeight: .infinity)
                detail
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading \(section.rawValue)")
    }

    private var inventory: some View {
        VStack(spacing: 0) {
            SkeletonBlock(height: UIScale.pt(24), corner: UIScale.pt(6))
                .padding(UIScale.pt(12))
            Divider()
            VStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    HStack(spacing: UIScale.pt(9)) {
                        if section == .updates {
                            SkeletonBlock(width: 14, height: 14, corner: 3)
                        }
                        SkeletonBlock(width: 28, height: 28, corner: 7)
                        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                            SkeletonBlock(
                                width: index.isMultiple(of: 2) ? 112 : 148,
                                height: 10)
                            SkeletonBlock(width: 82, height: 8)
                        }
                        Spacer(minLength: 0)
                        if section == .updates {
                            SkeletonBlock(width: 48, height: 8)
                        }
                    }
                    .padding(.horizontal, UIScale.pt(12))
                    .padding(.vertical, UIScale.pt(9))
                }
                Spacer(minLength: 0)
            }
            Divider()
            HStack {
                SkeletonBlock(width: 82, height: 8)
                Spacer()
                SkeletonBlock(width: 62, height: 8)
            }
            .padding(.horizontal, UIScale.pt(12))
            .frame(height: UIScale.pt(34))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .updates:
            AppMaintenanceUpdateSkeleton()
        case .removal:
            AppMaintenanceRemovalSkeleton()
        case .history:
            AppMaintenanceHistorySkeleton()
        case .packages:
            EmptyView()
        }
    }
}

private struct AppMaintenanceUpdateSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            HStack(spacing: UIScale.pt(14)) {
                SkeletonBlock(width: 54, height: 54, corner: 12)
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    SkeletonBlock(width: 156, height: 14)
                    SkeletonBlock(width: 104, height: 9)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: UIScale.pt(6)) {
                    SkeletonBlock(width: 86, height: 10)
                    SkeletonBlock(width: 72, height: 8)
                }
            }
            AppMaintenanceDetailSkeleton(lines: 4, height: 150)
            AppMaintenanceDetailSkeleton(lines: 2, height: 104)
            Spacer(minLength: 0)
            HStack {
                SkeletonBlock(width: 72, height: 30, corner: 7)
                Spacer()
                SkeletonBlock(width: 126, height: 32, corner: 7)
            }
        }
        .padding(UIScale.pt(22))
    }
}

private struct AppMaintenanceHistorySkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack(spacing: UIScale.pt(12)) {
                SkeletonBlock(width: 44, height: 44, corner: 11)
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    SkeletonBlock(width: 132, height: 14)
                    SkeletonBlock(width: 248, height: 9)
                }
            }
            ForEach(0..<4, id: \.self) { index in
                AppMaintenanceDetailSkeleton(lines: index.isMultiple(of: 2) ? 2 : 3, height: 92)
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(22))
    }
}

private struct AppMaintenanceDetailSkeleton: View {
    let lines: Int
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(9)) {
            SkeletonBlock(width: 94, height: 10)
            ForEach(0..<lines, id: \.self) { index in
                SkeletonBlock(
                    width: index == lines - 1 ? 214 : nil,
                    height: 8)
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, minHeight: UIScale.pt(height), alignment: .topLeading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
    }
}

private struct AppMaintenanceRemovalSkeleton: View {
    var body: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                HStack(spacing: UIScale.pt(12)) {
                    SkeletonBlock(width: 48, height: 48, corner: 10)
                    VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                        SkeletonBlock(width: 148, height: 14)
                        SkeletonBlock(width: 236, height: 9)
                        SkeletonBlock(width: 184, height: 9)
                    }
                    Spacer()
                    SkeletonBlock(width: 72, height: 28, corner: 7)
                }
                .padding(UIScale.pt(18))
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        SkeletonBlock(width: 76, height: 9)
                        Spacer()
                    }
                    .padding(.horizontal, UIScale.pt(16))
                    .padding(.top, UIScale.pt(14))
                    .padding(.bottom, UIScale.pt(7))
                    ForEach(0..<6, id: \.self) { index in
                        HStack(spacing: UIScale.pt(10)) {
                            SkeletonBlock(width: 14, height: 14, corner: 3)
                            SkeletonBlock(width: 22, height: 22, corner: 5)
                            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                                SkeletonBlock(
                                    width: index.isMultiple(of: 2) ? 132 : 176,
                                    height: 10)
                                SkeletonBlock(width: 248, height: 8)
                            }
                            Spacer()
                            SkeletonBlock(width: 48, height: 8)
                            SkeletonBlock(width: 24, height: 24, corner: 6)
                        }
                        .padding(.horizontal, UIScale.pt(16))
                        .padding(.vertical, UIScale.pt(9))
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                        SkeletonBlock(width: 112, height: 10)
                        SkeletonBlock(width: 62, height: 8)
                    }
                    Spacer()
                    SkeletonBlock(width: 104, height: 32, corner: 7)
                }
                .padding(UIScale.pt(16))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Finding exact support files")
    }
}

private struct AppMaintenanceApplicationRow: View {
    let application: InstalledApplication

    var body: some View {
        HStack(spacing: UIScale.pt(9)) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                .resizable()
                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(application.name)
                    .lineLimit(1)
                Text(application.version)
                    .settingsCaption()
            }
            Spacer(minLength: 0)
            if application.update != nil {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .help("Update available")
            }
        }
        .padding(.vertical, UIScale.pt(3))
    }
}

private struct AppMaintenanceItemRow: View {
    let item: AppMaintenanceItem
    @Binding var selected: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Toggle("", isOn: $selected)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: UIScale.pt(22), height: UIScale.pt(22))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                Text(
                    (item.url.deletingLastPathComponent().path as NSString)
                        .abbreviatingWithTildeInPath
                )
                .settingsCaption()
                .lineLimit(1)
                .truncationMode(.head)
            }
            Spacer()
            Text(JunkScanner.format(item.sizeBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.edith(.borderless))
            .help("Reveal in Finder")
        }
    }
}

private struct AppMaintenanceInstallReview: View {
    let plan: AppMaintenanceDiskImagePlan
    let installing: Bool
    let onCancel: () -> Void
    let onInstall: (Bool, Bool) -> Void
    @State private var replaceExisting = false
    @State private var moveImageToTrash = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(12)) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: plan.sourceApplication.url.path))
                    .resizable()
                    .frame(width: UIScale.pt(52), height: UIScale.pt(52))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text("Install \(plan.sourceApplication.name)")
                        .font(.system(size: UIScale.pt(18), weight: .semibold))
                    Text(
                        "\(plan.sourceApplication.bundleID) · \(plan.sourceApplication.version)"
                    )
                    .settingsCaption()
                }
                Spacer()
                Label("Verified", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            .padding(UIScale.pt(20))
            Divider()
            Form {
                Section("Reviewed installation") {
                    LabeledContent("Disk image", value: plan.imageURL.lastPathComponent)
                    LabeledContent("Image size", value: JunkScanner.format(plan.imageSizeBytes))
                    LabeledContent("Destination", value: plan.destinationURL.path)
                    LabeledContent("Code signature", value: "Accepted")
                    LabeledContent("Gatekeeper", value: "Accepted")
                }
                if let existing = plan.existingApplication {
                    Section("Existing application") {
                        LabeledContent("Installed version", value: existing.version)
                        Text(
                            "The existing app will move to the Trash before the verified replacement is installed."
                        )
                        .settingsCaption()
                        Toggle("Replace the existing application", isOn: $replaceExisting)
                    }
                }
                Section("Cleanup") {
                    Toggle("Move the disk image to Trash after ejecting", isOn: $moveImageToTrash)
                    Text(
                        "The app is staged and verified again before installation. The download only moves after the mounted image ejects successfully."
                    )
                    .settingsCaption()
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if installing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing verified application")
                        .settingsCaption()
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .disabled(installing)
                Button(plan.replacesExisting ? "Replace App" : "Install App") {
                    onInstall(replaceExisting, moveImageToTrash)
                }
                .buttonStyle(.borderedProminent)
                .disabled(installing || plan.replacesExisting && !replaceExisting)
            }
            .padding(UIScale.pt(16))
        }
        .frame(width: UIScale.pt(620), height: UIScale.pt(560))
        .interactiveDismissDisabled(installing)
    }
}
