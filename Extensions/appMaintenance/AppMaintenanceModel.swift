import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

typealias AppMaintenanceInventoryLoad = @Sendable (Data?) async -> [InstalledApplication]
typealias AppMaintenanceDiscover =
    @Sendable (
        [InstalledApplication], Data?, Bool,
        @escaping @Sendable (AppUpdateDiscoveryBatch) async -> Void
    ) async -> [AppUpdateItem]

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
    var previewToken = UUID()
    var selectedApplicationID: String? { didSet { previewToken = UUID() } }
    var plan: AppMaintenancePlan? { didSet { previewToken = UUID() } }
    var selectedItemIDs = Set<String>() { didSet { previewToken = UUID() } }
    var phase = Phase.loading
    var errorMessage: String?
    var resultMessage: String?
    var installPlan: AppMaintenanceDiskImagePlan? { didSet { previewToken = UUID() } }
    var updates: [AppUpdateItem] = [] {
        didSet {
            previewToken = UUID()
            try? ExtensionSharedState.current?.publish(["availableUpdates": String(updates.count)]
            )
        }
    }
    var updateHistory: [AppUpdateResult] = []
    var selectedUpdateIDs = Set<String>() { didSet { previewToken = UUID() } }
    var focusedUpdateID: String?
    var lastUpdateRefresh: Date?
    var checkingUpdates = false
    private var updateState = AppUpdateCenterState()
    private let updatePersistence: AppUpdatePersistence
    private let snapshots: AppMaintenanceSnapshotStore
    private let inventory: AppMaintenanceInventoryLoad
    private let discover: AppMaintenanceDiscover
    private let updateExecutor = AppUpdateExecutor()
    @ObservationIgnored private var operation: (id: UUID, cancellation: MaintenanceCancellation)?
    @ObservationIgnored private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var stopped = false
    var ownedOperationCount: Int { ownedTasks.count }
    var mutationInProgress: Bool {
        [.removing, .installing, .updating, .mounting].contains(phase)
    }
    let loading = ContentLoad()
    private var discovered: [AppUpdateItem] = []
    private var brewCache: Data?
    private var brewCachedAt: Date?
    private var reuseCachedBrew = false
    private var refreshInterval: TimeInterval = 86_400

    init(
        persistence: AppUpdatePersistence = AppUpdatePersistence(),
        snapshots: AppMaintenanceSnapshotStore = AppMaintenanceSnapshotStore(),
        inventory: @escaping AppMaintenanceInventoryLoad = { data in
            await BlockingWork.value { AppMaintenanceInventory.applications(updateData: data) }
        },
        discover: @escaping AppMaintenanceDiscover = { applications, brewData, brewFresh, onBatch in
            await AppUpdateDiscovery.discoverChannels(
                applications: applications, brewData: brewData, brewFresh: brewFresh,
                onBatch: onBatch)
        }
    ) {
        updatePersistence = persistence
        self.snapshots = snapshots
        self.inventory = inventory
        self.discover = discover
    }
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

    var focusedUpdate: AppUpdateItem? {
        if let focusedUpdateID,
            let update = updates.first(where: { $0.id == focusedUpdateID })
        {
            return update
        }
        return updates.first
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }

    func refresh(automatic: Bool = false, interval: TimeInterval = 86_400) {
        guard !stopped, !mutationInProgress else { return }
        cancelOperation()
        let generation = loading.begin()
        refreshInterval = interval
        var previousIDs: Set<String> = []
        previousIDs.reserveCapacity(updates.count)
        for update in updates { previousIDs.insert(update.id) }
        if applications.isEmpty, updates.isEmpty {
            phase = .loading
        }
        checkingUpdates = true
        errorMessage = nil
        resultMessage = nil
        launch { [self] cancellation in
            await self.performRefresh(
                generation: generation, automatic: automatic, interval: interval,
                previousIDs: previousIDs)
        }
    }

    private func performRefresh(
        generation: UInt64, automatic: Bool, interval: TimeInterval, previousIDs: Set<String>
    ) async {
        let claim = await snapshots.claim()
        guard !stopped, loading.isCurrent(generation) else { return }
        let snapshot = await snapshots.load()
        let state = await BlockingWork.value { [updatePersistence] in updatePersistence.load() }
        guard !stopped, loading.isCurrent(generation) else { return }
        updateState = state
        updateHistory = state.history
        lastUpdateRefresh = state.lastRefresh
        if applications.isEmpty, updates.isEmpty, let snapshot {
            applications = snapshot.applications
            discovered = snapshot.updates
            updates = updatePersistence.visible(snapshot.updates, state: state, now: Date())
            brewCache = snapshot.homebrewOutdated
            brewCachedAt = snapshot.homebrewCachedAt
            if !applications.isEmpty || !updates.isEmpty {
                phase = .ready
                loading.retainContent()
            }
        }
        let brewFresh = brewCachedAt.map { Date().timeIntervalSince($0) < interval } ?? false
        reuseCachedBrew = brewFresh
        let scanned = await inventory(brewFresh ? brewCache : nil)
        guard !stopped, loading.isCurrent(generation) else { return }
        let keptSelection = selectedApplicationID
        applications = scanned
        phase = .ready
        loading.retainContent()
        if let keptSelection, !scanned.contains(where: { $0.id == keptSelection }) {
            selectedApplicationID = nil
            plan = nil
            selectedItemIDs = []
        }
        let found = await discover(scanned, brewFresh ? brewCache : nil, brewFresh) { batch in
            await self.absorb(batch, generation: generation)
        }
        guard !stopped, loading.isCurrent(generation) else { return }
        discovered = found
        updates = updatePersistence.visible(found, state: updateState, now: Date())
        reconcileUpdates()
        updateState.lastRefresh = Date()
        lastUpdateRefresh = updateState.lastRefresh
        let stateToSave = updateState
        let snapshotToSave = AppMaintenanceSnapshot(
            applications: applications, updates: found, homebrewOutdated: brewCache,
            homebrewCachedAt: brewCachedAt)
        do {
            try await BlockingWork.perform { [updatePersistence] in
                try updatePersistence.save(stateToSave)
            }
            try await snapshots.save(snapshotToSave, replacing: claim)
        } catch {
            guard !stopped, loading.isCurrent(generation) else { return }
            errorMessage = error.localizedDescription
        }
        guard !stopped, loading.isCurrent(generation) else { return }
        checkingUpdates = false
        phase = .ready
        if let errorMessage {
            loading.fail(generation, message: errorMessage)
        } else {
            loading.complete(generation)
        }
        guard automatic, !Task.isCancelled else { return }
        var freshCount = 0
        for update in updates where !previousIDs.contains(update.id) { freshCount += 1 }
        if freshCount > 0 { await notify(updateCount: freshCount) }
    }

    private func absorb(_ batch: AppUpdateDiscoveryBatch, generation: UInt64) {
        guard !stopped, loading.isCurrent(generation) else { return }
        if batch.channel == .homebrew, let data = batch.homebrewData {
            applications = AppMaintenanceInventory.applyingHomebrewUpdates(data, to: applications)
            if brewCache != data || !reuseCachedBrew {
                brewCachedAt = Date()
            }
            brewCache = data
        }
        discovered = AppUpdateDiscovery.replacing(discovered, with: batch)
        updates = updatePersistence.visible(discovered, state: updateState, now: Date())
    }

    private func reconcileUpdates() {
        var visibleIDs: Set<String> = []
        visibleIDs.reserveCapacity(updates.count)
        for update in updates { visibleIDs.insert(update.id) }
        selectedUpdateIDs.formIntersection(visibleIDs)
        if selectedUpdateIDs.isEmpty { selectedUpdateIDs = visibleIDs }
        if let focusedUpdateID {
            if !visibleIDs.contains(focusedUpdateID) {
                self.focusedUpdateID = updates.first?.id
            }
        } else {
            focusedUpdateID = updates.first?.id
        }
    }

    func setUpdateSelected(_ selected: Bool, item: AppUpdateItem) {
        guard !stopped else { return }
        if selected {
            selectedUpdateIDs.insert(item.id)
        } else {
            selectedUpdateIDs.remove(item.id)
        }
    }

    func runSelectedUpdates(concurrency: Int, retries: Int) {
        guard !stopped, !mutationInProgress else { return }
        let selected = updates.filter { selectedUpdateIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        cancelOperation()
        phase = .updating
        errorMessage = nil
        resultMessage = nil
        launch { [self] cancellation in
            do {
                let results = try await updateExecutor.execute(
                    AppUpdatePlan(items: selected, concurrency: concurrency, retries: retries),
                    confirmed: true)
                guard !stopped, !Task.isCancelled else { return }
                updateState = updatePersistence.recording(results, in: updateState)
                try updatePersistence.save(updateState)
                updateHistory = updateState.history
                let succeeded = results.filter { $0.status == .succeeded }.count
                resultMessage = "Finished \(succeeded) of \(results.count) updates."
                phase = .ready
                refresh(interval: refreshInterval)
            } catch {
                guard !stopped, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func ignore(_ item: AppUpdateItem) {
        guard !stopped else { return }
        updateState.ignoredVersions[item.id] = item.availableVersion
        persistPolicy(removing: item)
    }

    func snooze(_ item: AppUpdateItem, until: Date) {
        guard !stopped else { return }
        updateState.snoozedUntil[item.id] = until
        persistPolicy(removing: item)
    }

    func exclude(_ item: AppUpdateItem) {
        guard !stopped else { return }
        guard let bundleID = item.bundleID else { return }
        updateState.excludedBundleIDs.insert(bundleID)
        persistPolicy(removing: item)
    }

    func resetUpdatePolicies() {
        guard !stopped else { return }
        updateState.ignoredVersions = [:]
        updateState.snoozedUntil = [:]
        updateState.excludedBundleIDs = []
        do {
            try updatePersistence.save(updateState)
            refresh(interval: refreshInterval)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistPolicy(removing item: AppUpdateItem) {
        do {
            try updatePersistence.save(updateState)
            updates.removeAll { $0.id == item.id }
            selectedUpdateIDs.remove(item.id)
            if focusedUpdateID == item.id { focusedUpdateID = updates.first?.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func notify(updateCount: Int) async {
        guard
            SharedDefaults.store.bool(
                forKey: MaintenancePreferences.updateNotifications)
        else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        guard !stopped, !Task.isCancelled else { return }
        let content = UNMutableNotificationContent()
        content.title = "App Update Center"
        content.body = "\(updateCount) new updates are available."
        try? await center.add(
            UNNotificationRequest(
                identifier: "app-update-center", content: content, trigger: nil))
    }

    func select(_ application: InstalledApplication) {
        guard !stopped, !mutationInProgress else { return }
        cancelOperation()
        selectedApplicationID = application.id
        plan = nil
        selectedItemIDs = []
        errorMessage = nil
        resultMessage = nil
        phase = .scanning
        launch { [self] cancellation in
            do {
                let loaded = try await BlockingWork.perform {
                    try AppMaintenanceExecution.plan(
                        applicationURL: application.url, isCancelled: { cancellation.isCancelled })
                }
                guard !stopped, !Task.isCancelled, selectedApplicationID == application.id else {
                    return
                }
                plan = loaded
                selectedItemIDs = Set(loaded.items.map(\.id))
                phase = .ready
            } catch {
                guard !stopped, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func setSelected(_ selected: Bool, item: AppMaintenanceItem) {
        guard !stopped else { return }
        if selected {
            selectedItemIDs.insert(item.id)
        } else {
            selectedItemIDs.remove(item.id)
        }
    }

    func removeSelected() {
        guard !stopped, !mutationInProgress else { return }
        guard let plan else { return }
        let selectedIDs = selectedItemIDs
        cancelOperation()
        phase = .removing
        errorMessage = nil
        resultMessage = nil
        launch { [self] cancellation in
            do {
                let result = try await BlockingWork.perform {
                    try AppMaintenanceExecution.remove(
                        plan: plan, selectedIDs: selectedIDs,
                        isCancelled: { cancellation.isCancelled })
                }
                guard !stopped, !Task.isCancelled else { return }
                if result.failed.isEmpty {
                    resultMessage =
                        "Moved \(result.removed.count) items, \(AppMaintenanceFiles.format(result.reclaimedBytes)), to the Trash."
                } else {
                    resultMessage =
                        "Moved \(result.removed.count) items to the Trash. \(result.failed.count) items could not be moved."
                }
                applications = await inventory(nil)
                guard !stopped, !Task.isCancelled else { return }
                selectedApplicationID = nil
                self.plan = nil
                selectedItemIDs = []
                phase = .ready
            } catch {
                guard !stopped, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func prepareDiskImage(_ url: URL, destination: AppMaintenanceInstallDestination) {
        guard !stopped, !mutationInProgress else { return }
        cancelOperation()
        cancelInstallPlan()
        phase = .mounting
        errorMessage = nil
        resultMessage = nil
        launch { [self] cancellation in
            let accessing = url.startAccessingSecurityScopedResource()
            var retainedAccess = false
            defer {
                if accessing, !retainedAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let prepared = try await AppMaintenanceDiskImageInstaller.plan(
                    imageURL: url, destination: destination)
                guard !stopped, !Task.isCancelled else {
                    await AppMaintenanceDiskImageInstaller.cancel(plan: prepared)
                    return
                }
                securityScopedURL = url
                hasSecurityScopedAccess = accessing
                retainedAccess = true
                installPlan = prepared
                phase = .ready
            } catch {
                guard !stopped, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func installDiskImage(replaceExisting: Bool, moveImageToTrash: Bool) {
        guard !stopped, !mutationInProgress else { return }
        guard let installPlan else { return }
        cancelOperation()
        phase = .installing
        errorMessage = nil
        resultMessage = nil
        launch { [self] cancellation in
            defer { releaseSecurityScopedAccess() }
            do {
                let result = try await AppMaintenanceDiskImageInstaller.install(
                    plan: installPlan, replaceExisting: replaceExisting,
                    moveImageToTrash: moveImageToTrash)
                if result.ejected { self.installPlan = nil }
                guard !stopped, !Task.isCancelled else { return }
                applications = await inventory(nil)
                guard !stopped, !Task.isCancelled else { return }
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
                guard !stopped, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func cancelInstallPlan() {
        if let installPlan {
            self.installPlan = nil
            trackCleanup { await AppMaintenanceDiskImageInstaller.cancel(plan: installPlan) }
        }
        releaseSecurityScopedAccess()
    }

    func cancel() {
        loading.cancel()
        cancelOperation()
        if phase != .installing { cancelInstallPlan() }
    }

    func finishWork() async {
        guard let operation, let task = ownedTasks[operation.id] else { return }
        await task.value
    }

    func backupUpdates(to destination: URL) throws {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try updatePersistence.backup(to: destination)
    }

    private func cancelOperation() {
        guard let operation else { return }
        operation.cancellation.cancel()
        ownedTasks[operation.id]?.cancel()
    }

    private func launch(_ action: @escaping @MainActor (MaintenanceCancellation) async -> Void) {
        guard !stopped else { return }
        cancelOperation()
        let id = UUID()
        let cancellation = MaintenanceCancellation()
        operation = (id, cancellation)
        ownedTasks[id] = Task {
            defer {
                ownedTasks[id] = nil
                if operation?.id == id { operation = nil }
            }
            await withTaskCancellationHandler {
                await action(cancellation)
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    private func trackCleanup(_ action: @escaping @MainActor () async -> Void) {
        let id = UUID()
        ownedTasks[id] = Task {
            defer { ownedTasks[id] = nil }
            await action()
        }
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        cancel()
        while let task = ownedTasks.values.first { await task.value }
        cancelInstallPlan()
        while let task = ownedTasks.values.first { await task.value }
        releaseSecurityScopedAccess()
        applications = []
        updates = []
        updateHistory = []
        discovered = []
        brewCache = nil
        plan = nil
        selectedItemIDs = []
        selectedUpdateIDs = []
        checkingUpdates = false
        loading.reset()
    }

    func openExtension(_ id: String) {
        guard !stopped else { return }
        trackCleanup { [self] in
            do {
                guard let endpoint = ExtensionPeerEndpoint.current(owner: id) else {
                    throw ExtensionPeerError.unavailable
                }
                _ = try await endpoint.invoke("extension.open", payload: Data(), timeout: 3)
            } catch {
                guard !stopped else { return }
                errorMessage =
                    "Download and enable this extension in Extensions, then open it here."
            }
        }
    }

    private func releaseSecurityScopedAccess() {
        if hasSecurityScopedAccess { securityScopedURL?.stopAccessingSecurityScopedResource() }
        securityScopedURL = nil
        hasSecurityScopedAccess = false
    }
}
