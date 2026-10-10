import AppKit
import IOKit.ps
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
    enum Phase: String, Codable, Equatable {
        case loading
        case ready
        case scanning
        case removing
        case mounting
        case installing
        case updating
    }

    var preferences = MaintenanceUISettings()
    let preferenceDefaults: UserDefaults
    private var preferencesTask: Task<Void, Never>?
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
    private var remoteIcons: [String: Data] = [:]
    private var engineClient: ExtensionEngineClient?
    private var remoteTask: Task<Void, Never>?
    private var remoteRevision = 0
    private var applyingRemote = false
    private var updateState = AppUpdateCenterState()
    private let updatePersistence: AppUpdatePersistence
    private let snapshots: AppMaintenanceSnapshotStore
    private let inventory: AppMaintenanceInventoryLoad
    private let discover: AppMaintenanceDiscover
    private let now: @Sendable () -> Date
    private var backgroundDiscovery: Task<Void, Never>?
    private var loadedBackgroundSnapshot = false
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
        defaults: UserDefaults = SharedDefaults.store,
        persistence: AppUpdatePersistence = AppUpdatePersistence(),
        snapshots: AppMaintenanceSnapshotStore = AppMaintenanceSnapshotStore(),
        inventory: @escaping AppMaintenanceInventoryLoad = { data in
            await BlockingWork.value { AppMaintenanceInventory.applications(updateData: data) }
        },
        now: @escaping @Sendable () -> Date = { Date() },
        discover: @escaping AppMaintenanceDiscover = { applications, brewData, brewFresh, onBatch in
            await AppUpdateDiscovery.discoverChannels(
                applications: applications, brewData: brewData, brewFresh: brewFresh,
                onBatch: onBatch)
        }
    ) {
        preferenceDefaults = defaults
        preferences = MaintenanceUISettings.load(defaults)
        updatePersistence = persistence
        self.snapshots = snapshots
        self.inventory = inventory
        self.discover = discover
        self.now = now
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

    convenience init(engineClient: ExtensionEngineClient) {
        self.init()
        self.engineClient = engineClient
    }

    var visiblePaths: Set<String> {
        Set(
            applications.map { $0.url.path } + (plan?.items.map { $0.url.path } ?? [])
                + updates.compactMap(\.applicationPath)
                + [installPlan?.sourceApplication.url.path].compactMap { $0 })
    }
    func icon(for path: String) -> NSImage {
        if engineClient != nil {
            return remoteIcons[path].flatMap(NSImage.init(data:)) ?? NSImage(
                named: NSImage.applicationIconName) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: path)
    }
    private func snapshotIcons() -> [String: Data] {
        var result: [String: Data] = [:]
        for path in visiblePaths.sorted().prefix(256) {
            let original = NSWorkspace.shared.icon(forFile: path)
            let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                original.draw(in: rect); return true
            }
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            {
                result[path] = png
            }
        }
        return result
    }
    func reveal(_ url: URL) {
        if engineClient != nil { sendRemote("reveal", value: url.path); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func uiSnapshot() -> AppMaintenanceUISnapshot {
        .init(
            preferences: preferences, icons: snapshotIcons(), applications: applications,
            previewToken: previewToken,
            selectedApplicationID: selectedApplicationID,
            plan: plan, selectedItemIDs: selectedItemIDs, phase: phase, errorMessage: errorMessage,
            resultMessage: resultMessage,
            installPlan: installPlan, updates: updates, updateHistory: updateHistory,
            selectedUpdateIDs: selectedUpdateIDs,
            focusedUpdateID: focusedUpdateID, lastUpdateRefresh: lastUpdateRefresh,
            checkingUpdates: checkingUpdates)
    }

    func updatePreferences(_ change: (inout MaintenanceUISettings) -> Void) {
        guard !stopped else { return }
        var next = preferences; change(&next)
        if let engineClient {
            preferences = next; preferencesTask?.cancel()
            preferencesTask = Task { [weak self] in
                do {
                    let data = try await engineClient.invoke(
                        "maintenance.ui.preferences", payload: JSONEncoder().encode(next))
                    guard let self, !stopped, !Task.isCancelled else { return }
                    preferences = try JSONDecoder().decode(
                        AppMaintenanceUISnapshot.self, from: data
                    ).preferences
                } catch is CancellationError {} catch {
                    guard let self, !stopped else { return };
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            do { try next.save(preferenceDefaults); preferences = next } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshRemote() async {
        guard let engineClient, !stopped else { return }
        let revision = remoteRevision
        do {
            let data = try await engineClient.invoke("maintenance.ui.snapshot")
            guard !stopped, !Task.isCancelled, revision == remoteRevision else { return }
            applyRemote(try JSONDecoder().decode(AppMaintenanceUISnapshot.self, from: data))
        } catch is CancellationError {} catch {
            if !stopped { errorMessage = error.localizedDescription }
        }
    }

    private func applyRemote(_ value: AppMaintenanceUISnapshot) {
        preferences = value.preferences
        remoteIcons = value.icons
        applyingRemote = true
        defer { applyingRemote = false }
        applications = value.applications; selectedApplicationID = value.selectedApplicationID;
        plan = value.plan
        selectedItemIDs = value.selectedItemIDs; phase = value.phase;
        errorMessage = value.errorMessage; resultMessage = value.resultMessage
        installPlan = value.installPlan; updates = value.updates;
        updateHistory = value.updateHistory
        selectedUpdateIDs = value.selectedUpdateIDs; lastUpdateRefresh = value.lastUpdateRefresh;
        checkingUpdates = value.checkingUpdates
        previewToken = value.previewToken
        if value.phase == .loading {
            if !loading.isRunning { _ = loading.begin() }
        } else if let error = value.errorMessage, value.applications.isEmpty {
            loading.fail(loading.begin(), message: error)
        } else {
            loading.setContent()
        }
    }

    private func sendRemote(
        _ operation: String, value: String? = nil, item: String? = nil, enabled: Bool? = nil,
        integer: Int? = nil, number: Double? = nil
    ) {
        guard let engineClient, !stopped, !applyingRemote else { return }
        remoteTask?.cancel(); remoteRevision += 1
        let revision = remoteRevision
        let request = AppMaintenanceUIAction(
            operation: operation, value: value, item: item, enabled: enabled, integer: integer,
            number: number, previewToken: previewToken)
        remoteTask = Task {
            defer { if revision == remoteRevision { remoteTask = nil } }
            do {
                let payload = try JSONEncoder().encode(request)
                let data = try await engineClient.invoke("maintenance.ui.action", payload: payload)
                guard !stopped, !Task.isCancelled, revision == remoteRevision else { return }
                applyRemote(try JSONDecoder().decode(AppMaintenanceUISnapshot.self, from: data))
            } catch is CancellationError {} catch {
                if !stopped, revision == remoteRevision {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func refresh(automatic: Bool = false, interval: TimeInterval = 86_400) {
        if engineClient != nil, !stopped {
            sendRemote("refresh", enabled: automatic, number: interval); return
        }
        guard !stopped, !mutationInProgress, !checkingUpdates || operation == nil else { return }
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

    func startBackgroundDiscovery(
        onBattery: @escaping @MainActor () -> Bool = {
            guard let sources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
                return false
            }
            return IOPSGetProvidingPowerSourceType(sources).takeUnretainedValue() as String
                == kIOPMBatteryPowerKey
        },
        delay: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        guard !stopped, engineClient == nil, backgroundDiscovery == nil else { return }
        backgroundDiscovery = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !stopped else { return }
                await discoverIfDue(onBattery: onBattery())
                do { try await delay(.seconds(60)) } catch { return }
            }
        }
    }

    func discoverIfDue(onBattery: Bool) async {
        guard !stopped, !Task.isCancelled, engineClient == nil, !onBattery,
            !mutationInProgress, operation == nil
        else { return }
        if !loadedBackgroundSnapshot {
            let state = await BlockingWork.value { [updatePersistence] in updatePersistence.load() }
            let snapshot = await snapshots.load()
            guard !stopped, !Task.isCancelled, operation == nil else { return }
            loadedBackgroundSnapshot = true
            updateState = state
            updateHistory = state.history
            lastUpdateRefresh = state.lastRefresh
            if let snapshot, applications.isEmpty, updates.isEmpty {
                applications = snapshot.applications
                discovered = snapshot.updates
                updates = updatePersistence.visible(snapshot.updates, state: state, now: now())
                brewCache = snapshot.homebrewOutdated
                brewCachedAt = snapshot.homebrewCachedAt
                phase = .ready
                loading.retainContent()
            }
        }
        guard lastUpdateRefresh.map({ now().timeIntervalSince($0) < 21_600 }) != true else {
            return
        }
        refresh(interval: 21_600)
        await withTaskCancellationHandler {
            await finishWork()
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelOperation() }
        }
    }

    func stopBackgroundDiscovery() {
        backgroundDiscovery?.cancel()
        cancelOperation()
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
        loadedBackgroundSnapshot = true
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
        updateState.lastRefresh = now()
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
        if engineClient != nil, !stopped {
            sendRemote("updateSelection", value: item.id, enabled: selected); return
        }
        guard !stopped else { return }
        if selected {
            selectedUpdateIDs.insert(item.id)
        } else {
            selectedUpdateIDs.remove(item.id)
        }
    }

    func runSelectedUpdates(concurrency: Int, retries: Int) {
        if engineClient != nil, !stopped {
            sendRemote("update", integer: concurrency, number: Double(retries)); return
        }
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
        if engineClient != nil, !stopped { sendRemote("ignore", value: item.id); return }
        guard !stopped else { return }
        updateState.ignoredVersions[item.id] = item.availableVersion
        persistPolicy(removing: item)
    }

    func snooze(_ item: AppUpdateItem, until: Date) {
        if engineClient != nil, !stopped {
            sendRemote("snooze", value: item.id, number: until.timeIntervalSince1970); return
        }
        guard !stopped else { return }
        updateState.snoozedUntil[item.id] = until
        persistPolicy(removing: item)
    }

    func exclude(_ item: AppUpdateItem) {
        if engineClient != nil, !stopped { sendRemote("exclude", value: item.id); return }
        guard !stopped else { return }
        guard let bundleID = item.bundleID else { return }
        updateState.excludedBundleIDs.insert(bundleID)
        persistPolicy(removing: item)
    }

    func resetUpdatePolicies() {
        if engineClient != nil, !stopped { sendRemote("reset"); return }
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
        if engineClient != nil, !stopped { sendRemote("select", value: application.id); return }
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
        if engineClient != nil, !stopped {
            sendRemote("selection", value: item.id, enabled: selected); return
        }
        guard !stopped else { return }
        if selected {
            selectedItemIDs.insert(item.id)
        } else {
            selectedItemIDs.remove(item.id)
        }
    }

    func removeSelected() {
        if engineClient != nil, !stopped { sendRemote("remove"); return }
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
        if engineClient != nil, !stopped {
            sendRemote("prepareImage", value: url.path, item: destination.rawValue); return
        }
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
        if engineClient != nil, !stopped {
            sendRemote("install", enabled: replaceExisting, integer: moveImageToTrash ? 1 : 0);
            return
        }
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
        if engineClient != nil, !stopped { sendRemote("cancelImage"); return }
        if let installPlan {
            self.installPlan = nil
            trackCleanup { await AppMaintenanceDiskImageInstaller.cancel(plan: installPlan) }
        }
        releaseSecurityScopedAccess()
    }

    func cancel() {
        if engineClient != nil, !stopped { sendRemote("cancel"); return }
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
        stopBackgroundDiscovery()
        await backgroundDiscovery?.value
        backgroundDiscovery = nil
        preferencesTask?.cancel(); await preferencesTask?.value; preferencesTask = nil
        remoteRevision += 1; remoteTask?.cancel(); await remoteTask?.value; remoteTask = nil
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
        if engineClient != nil, !stopped { sendRemote("openExtension", value: id); return }
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
