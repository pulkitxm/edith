import AppKit
import IOKit.ps
import EdithExtensionSupport
import EdithExtensionUI
import Observation
import SwiftUI

struct CleanerEstimateSnapshot: Codable, Sendable {
    let scannedAt: Date
    let reclaimableBytes: Int64
    let categoryCount: Int
}

@MainActor
@Observable
final class CleanerModel {
    private static let confirmedExternalPathsKey = "cleanerConfirmedExternalPaths"
    private static let selectedDrivesKey = "cleanerSelectedDrives"
    private static let customFoldersKey = "cleanerCustomFolders"
    private static let selectionKey = "cleanerSelection"
    private static let legacySelectionKeys = [
        "cleanerSelectionOverrides", "cleanerCategoryDefaults",
    ]
    private static let filtersKey = "cleanerFilters"
    static let backgroundEstimateKey = "cleaner.backgroundEstimate"

    @ObservationIgnored private(set) var revision = 0
    private(set) var previewToken = UUID() {
        didSet { revision &+= 1 }
    }
    private(set) var categories: [JunkCategory] = [] {
        didSet {
            revision &+= 1
            refreshList()
            rebuildIndex()
            publishReclaimable()
        }
    }
    private(set) var list = CleanerListState()
    private(set) var selection = CleanerSelection()
    private(set) var stats = CleanerSelectionStats()
    @ObservationIgnored private var index = CleanerSelectionIndex()
    @ObservationIgnored private(set) var selectionRevision = 0
    @ObservationIgnored private var remoteSelectionStamp: Int?
    @ObservationIgnored private var selectionSave: Task<Void, Never>?
    @ObservationIgnored private var selectionDirty = false
    @ObservationIgnored private var publishedReclaimable: Int64?
    private(set) var scanning = false {
        didSet { revision &+= 1 }
    }
    private(set) var scanned = false {
        didSet { revision &+= 1 }
    }
    private(set) var logs: [String] = [] {
        didSet { revision &+= 1 }
    }
    var logsExpanded = false {
        didSet { rememberUIState() }
    }
    private(set) var lastReclaimed: Int64 = 0 {
        didSet { revision &+= 1 }
    }
    private(set) var drives: [DriveInfo] = [] {
        didSet { revision &+= 1 }
    }
    private(set) var driveOptions: [DriveInfo] = [] {
        didSet { revision &+= 1 }
    }
    let driveOptionsLoad = ContentLoad()
    var loadingDriveOptions: Bool {
        remote ? remoteLoadingDriveOptions || driveRequestInFlight : driveOptionsLoad.isRunning
    }
    private var remoteLoadingDriveOptions = false
    private var driveRequestInFlight = false
    private(set) var customFolders: [String] = [] {
        didSet { revision &+= 1 }
    }
    private(set) var filters = CleanerFilters() {
        didSet {
            revision &+= 1
            refreshList()
            rebuildIndex()
        }
    }
    var search = "" {
        didSet {
            rememberUIState()
            refreshList()
        }
    }
    private(set) var expanded: Set<String> = [] {
        didSet {
            rememberUIState()
            refreshList()
        }
    }
    private(set) var itemFilters: [String: String] = [:] {
        didSet { refreshList() }
    }
    private var driveSelection: Set<String>? {
        didSet { revision &+= 1 }
    }
    private var scanToken: CleanerCancellation?
    private let defaults: UserDefaults
    private let services: CleanerServices
    private let now: @Sendable () -> Date
    private var backgroundEstimates: Task<Void, Never>?
    private(set) var latestEstimate: CleanerEstimateSnapshot?
    private var suspending = false
    private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private var workTask: Task<Void, Never>?
    private var driveTask: Task<Void, Never>?
    private var engineClient: ExtensionEngineClient?
    private var remoteGeneration = 0
    private var remoteQueue: [CleanerUIAction] = []
    private var remoteDrain: Task<Void, Never>?
    private var logCollapse: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?
    private var estimateToken: CleanerCancellation?
    private var cleaning = false
    private(set) var stopped = false
    private(set) var operationTitle = "Scanning…" {
        didSet { revision &+= 1 }
    }
    @ObservationIgnored private var remoteStamp: Int?
    private let sizeText = CleanerSizeText()

    var uiStamp: Int { revision &* 2 &+ (driveOptionsLoad.isRunning ? 1 : 0) }

    private func refreshList() {
        let updated = CleanerListState(
            categories: categories, filters: filters, search: search, expanded: expanded,
            itemFilters: itemFilters, now: now(), sizeText: sizeText)
        if updated != list { list = updated }
    }

    private func rebuildIndex() {
        index = CleanerSelectionIndex(
            visible: list.visibleCategories, all: categories, selection: selection)
        stats = index.stats
    }

    private func replaceSelection(_ value: CleanerSelection) {
        selection = value
        index.reload(value)
        stats = index.stats
    }

    private func publishReclaimable() {
        guard !remote, publishedReclaimable != list.reclaimableTotal else { return }
        publishedReclaimable = list.reclaimableTotal
        try? ExtensionSharedState.current?.publish([
            "reclaimableBytes": String(list.reclaimableTotal)
        ])
    }

    init(
        scanned: Bool = false, defaults: UserDefaults = SharedDefaults.store,
        services: CleanerServices = CleanerServices(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.services = services
        self.now = now
        self.scanned = scanned
        if let data = defaults.data(forKey: Self.backgroundEstimateKey), data.count <= 1_024,
            let estimate = try? JSONDecoder().decode(CleanerEstimateSnapshot.self, from: data),
            estimate.scannedAt.timeIntervalSince1970.isFinite,
            estimate.scannedAt <= now(), estimate.reclaimableBytes >= 0,
            (0...10_000).contains(estimate.categoryCount)
        {
            latestEstimate = estimate
            try? ExtensionSharedState.current?.publish([
                "reclaimableBytes": String(estimate.reclaimableBytes)
            ])
        }
        reloadPreferences()
    }

    func reloadPreferences() {
        let confirmed = Set(
            defaults.array(forKey: Self.confirmedExternalPathsKey) as? [String] ?? [])
        if let raw = defaults.array(forKey: Self.selectedDrivesKey) as? [String] {
            let kept = raw.filter { Self.pathIsAllowed($0, confirmed: confirmed) }
            driveSelection = Set(kept)
        }
        if let raw = defaults.array(forKey: Self.customFoldersKey) as? [String] {
            let kept = raw.filter { Self.pathIsAllowed($0, confirmed: confirmed) }
            customFolders = kept
        }
        for key in Self.legacySelectionKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
        if let data = defaults.data(forKey: Self.filtersKey), data.count <= 1_024,
            let stored = try? JSONDecoder().decode(CleanerFilters.self, from: data)
        {
            filters = stored
        }
    }

    convenience init(engineClient: ExtensionEngineClient, defaults: UserDefaults) {
        self.init(defaults: defaults)
        self.engineClient = engineClient
        if let memory = Self.uiMemory {
            seed(memory.snapshot)
            replaceSelection(memory.selection)
            logsExpanded = memory.logsExpanded
            search = memory.search
            expanded = memory.expanded
        }
    }

    struct UIMemory {
        var snapshot: CleanerUISnapshot
        var selection: CleanerSelection
        var logsExpanded: Bool
        var search: String
        var expanded: Set<String>
    }
    static var uiMemory: UIMemory?

    private func rememberUIState() {
        guard remote, var memory = Self.uiMemory else { return }
        memory.logsExpanded = logsExpanded
        memory.search = search
        memory.expanded = expanded
        Self.uiMemory = memory
    }

    var remote: Bool { engineClient != nil }

    func uiSnapshot() -> CleanerUISnapshot {
        .init(
            previewToken: previewToken, categories: categories, scanning: scanning,
            scanned: scanned,
            logs: logs, lastReclaimed: lastReclaimed, drives: drives, driveOptions: driveOptions,
            customFolders: customFolders, driveSelection: driveSelection,
            operationTitle: operationTitle,
            loadingDriveOptions: remote ? remoteLoadingDriveOptions : driveOptionsLoad.isRunning,
            filters: filters)
    }

    func refreshRemote() async {
        guard let task = track({ [self] in await refreshRemoteWork() }) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func refreshRemoteWork() async {
        guard let engineClient, !stopped, !suspending, remoteDrain == nil, remoteQueue.isEmpty
        else { return }
        let generation = remoteGeneration
        do {
            let request = try JSONEncoder().encode(
                CleanerUISnapshotRequest(known: remoteStamp, knownSelection: remoteSelectionStamp))
            let data = try await engineClient.invoke("cleaner.ui.snapshot", payload: request)
            guard !stopped, !suspending, !Task.isCancelled, generation == remoteGeneration else {
                return
            }
            applyRemote(try JSONDecoder().decode(CleanerUIReply.self, from: data))
        } catch is CancellationError {} catch {
            if !stopped, !suspending { log(error.localizedDescription) }
        }
    }

    private func seed(_ value: CleanerUISnapshot) {
        if categories != value.categories { categories = value.categories }
        if previewToken != value.previewToken { previewToken = value.previewToken }
        if scanning != value.scanning { scanning = value.scanning }
        if scanned != value.scanned { scanned = value.scanned }
        if logs != value.logs { logs = value.logs }
        if lastReclaimed != value.lastReclaimed { lastReclaimed = value.lastReclaimed }
        if drives != value.drives { drives = value.drives }
        if driveOptions != value.driveOptions { driveOptions = value.driveOptions }
        if customFolders != value.customFolders { customFolders = value.customFolders }
        if driveSelection != value.driveSelection { driveSelection = value.driveSelection }
        if operationTitle != value.operationTitle { operationTitle = value.operationTitle }
        if remoteLoadingDriveOptions != value.loadingDriveOptions {
            remoteLoadingDriveOptions = value.loadingDriveOptions
        }
        if filters != value.filters { filters = value.filters }
    }

    private func applyRemote(_ reply: CleanerUIReply) {
        remoteStamp = reply.stamp
        remoteSelectionStamp = reply.selectionStamp
        if let value = reply.selection, value != selection { replaceSelection(value) }
        guard let value = reply.snapshot else {
            Self.uiMemory?.selection = selection
            return
        }
        let wasScanning = scanning
        seed(value)
        Self.uiMemory = UIMemory(
            snapshot: value, selection: selection, logsExpanded: logsExpanded, search: search,
            expanded: expanded)
        if value.scanning, !wasScanning {
            logCollapse?.cancel()
            logCollapse = nil
            logsExpanded = true
        } else if !value.scanning, wasScanning, value.scanned {
            collapseLogsSoon()
        }
    }

    private func collapseLogsSoon() {
        logCollapse?.cancel()
        logCollapse = track { [self] in
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            guard !stopped, !suspending, !scanning else { return }
            withAnimation(.easeInOut(duration: 0.35)) { logsExpanded = false }
        }
    }

    private func sendRemote(
        _ operation: String, value: String? = nil, item: String? = nil, search: String? = nil
    ) {
        guard engineClient != nil, !stopped, !suspending, remoteQueue.count < 64 else { return }
        remoteGeneration += 1
        remoteQueue.append(
            CleanerUIAction(
                operation: operation, value: value, item: item, previewToken: previewToken,
                search: search))
        guard remoteDrain == nil else { return }
        remoteDrain = track { [self] in
            defer { remoteDrain = nil }
            guard let engineClient else { return }
            var latest: CleanerUIReply?
            var failed = false
            defer { if failed { remoteStamp = nil; remoteSelectionStamp = nil } }
            while !remoteQueue.isEmpty {
                var request = remoteQueue.removeFirst()
                let current = latest == nil && !failed
                request.known = current ? remoteStamp : nil
                request.knownSelection = current ? remoteSelectionStamp : nil
                do {
                    let payload = try JSONEncoder().encode(request)
                    let data = try await engineClient.invoke(
                        "cleaner.ui.action", payload: payload, timeout: 30)
                    guard !stopped, !suspending, !Task.isCancelled else { return }
                    let reply = try JSONDecoder().decode(CleanerUIReply.self, from: data)
                    if reply.snapshot == nil, reply.selection == nil, current {
                        remoteStamp = reply.stamp
                        remoteSelectionStamp = reply.selectionStamp
                        Self.uiMemory?.snapshot = uiSnapshot()
                        Self.uiMemory?.selection = selection
                    } else {
                        latest = reply
                    }
                } catch is CancellationError {
                    failed = true
                    return
                } catch {
                    failed = true
                    guard !stopped, !suspending else { return }
                    log(error.localizedDescription)
                }
                if request.operation == "drives" { driveRequestInFlight = false }
            }
            if let latest { applyRemote(latest) }
        }
    }

    func addCustomFolder(_ path: String) {
        if remote { sendRemote("addFolder", value: path); return }
        guard !stopped, !suspending else { return }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !customFolders.contains(standardizedPath) else { return }
        confirmExternalPathIfNeeded(standardizedPath)
        customFolders.append(standardizedPath)
        defaults.set(customFolders, forKey: Self.customFoldersKey)
        var selection = driveSelection ?? ["/"]
        selection.insert(standardizedPath)
        driveSelection = selection
        defaults.set(Array(selection), forKey: Self.selectedDrivesKey)
    }

    func removeCustomFolder(_ path: String) {
        if remote { sendRemote("removeFolder", value: path); return }
        guard !stopped, !suspending else { return }
        customFolders.removeAll { $0 == path }
        defaults.set(customFolders, forKey: Self.customFoldersKey)
        driveSelection?.remove(path)
        if driveSelection != nil {
            defaults.set(Array(driveSelection ?? []), forKey: Self.selectedDrivesKey)
        }
        removeExternalConfirmation(path)
    }

    var reclaimableTotal: Int64 { list.reclaimableTotal }
    var visibleCategories: [JunkCategory] { selection.applied(to: list.visibleCategories) }
    var selectedTotal: Int64 { stats.selectedBytes }
    var totalItemCount: Int { list.totalItemCount }
    var hiddenItemCount: Int { list.hiddenItemCount }
    var selectedItemCount: Int { stats.selectedCount }

    func selectedTotal(categoryID: String) -> Int64 {
        stats.categories[categoryID]?.selectedBytes ?? 0
    }

    func selectedItemCount(categoryID: String) -> Int {
        stats.categories[categoryID]?.selectedCount ?? 0
    }

    func categorySelection(_ categoryID: String) -> JunkSelection {
        stats.categories[categoryID]?.selection ?? .none
    }

    func isSelected(categoryID: String, itemID: String) -> Bool {
        selection.includes(itemID, categoryID: categoryID)
    }

    var age: CleanerAge {
        CleanerAge.allCases.first { $0.seconds == filters.minimumAge } ?? .any
    }

    func setAge(_ age: CleanerAge) {
        var updated = filters
        updated.minimumAge = age.seconds
        updateFilters(updated)
    }

    func setProtectDirty(_ protect: Bool) {
        var updated = filters
        updated.protectDirty = protect
        updateFilters(updated)
    }

    func setSort(_ sort: CleanerSort) {
        var updated = filters
        updated.sort = sort
        updateFilters(updated)
    }

    func updateFilters(_ updated: CleanerFilters) {
        guard !stopped, !suspending, updated != filters else { return }
        filters = updated
        if remote {
            let value = (try? JSONEncoder().encode(updated)).map {
                String(decoding: $0, as: UTF8.self)
            }
            sendRemote("filters", value: value)
            return
        }
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.filtersKey)
        }
    }

    var overallSelection: JunkSelection {
        let query = search.lowercased()
        return query.isEmpty ? stats.selection : index.selection(of: index.scopes(matching: query))
    }

    func setItemFilter(_ text: String, categoryID: String) {
        guard itemFilters[categoryID, default: ""] != text else { return }
        itemFilters[categoryID] = text.isEmpty ? nil : text
    }

    func loadDriveOptions() {
        if remote { driveRequestInFlight = true; sendRemote("drives"); return }
        guard !stopped, !suspending else { return }
        driveTask?.cancel()
        driveOptionsLoad.begin()
        driveTask = track { [self] in
            await driveOptionsLoad.perform(operation: { [services] in await services.drives() }) {
                guard !stopped, !suspending else { return }
                driveOptions = $0
            }
        }
    }

    func isDriveSelected(_ id: String) -> Bool {
        driveSelection?.contains(id) ?? (id == "/")
    }

    func toggleDrive(_ id: String) {
        if remote { sendRemote("drive", value: id); return }
        guard !stopped, !suspending else { return }
        var selection = driveSelection ?? ["/"]
        if selection.contains(id) {
            selection.remove(id)
            if !customFolders.contains(id) { removeExternalConfirmation(id) }
        } else {
            confirmExternalPathIfNeeded(id)
            selection.insert(id)
        }
        driveSelection = selection
        defaults.set(Array(selection), forKey: Self.selectedDrivesKey)
    }

    private static func pathIsAllowed(_ path: String, confirmed: Set<String>) -> Bool {
        RestoredPathValidation.verdict(for: path) == .keep
            || confirmed.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    private func confirmExternalPathIfNeeded(_ path: String) {
        guard RestoredPathValidation.verdict(for: path) == .drop else { return }
        var confirmed = Set(
            defaults.array(forKey: Self.confirmedExternalPathsKey) as? [String] ?? [])
        confirmed.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
        defaults.set(Array(confirmed), forKey: Self.confirmedExternalPathsKey)
    }

    private func removeExternalConfirmation(_ path: String) {
        var confirmed = Set(
            defaults.array(forKey: Self.confirmedExternalPathsKey) as? [String] ?? [])
        confirmed.remove(URL(fileURLWithPath: path).standardizedFileURL.path)
        defaults.set(Array(confirmed), forKey: Self.confirmedExternalPathsKey)
    }

    func startBackgroundEstimates(
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
        guard !stopped, !suspending, !remote, backgroundEstimates == nil else { return }
        backgroundEstimates = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !stopped, !suspending else { return }
                await estimateIfDue(onBattery: onBattery())
                do { try await delay(.seconds(60)) } catch { return }
            }
        }
    }

    func estimateIfDue(onBattery: Bool) async {
        guard !stopped, !suspending, !remote, !Task.isCancelled, !onBattery, !scanning,
            workTask == nil, estimateTask == nil,
            latestEstimate.map({ now().timeIntervalSince($0.scannedAt) < 604_800 }) != true
        else { return }
        let token = CleanerCancellation()
        estimateToken = token
        guard
            let task = track({ [self, services] in
                let result = await services.scan([], token) { _ in }
                guard !stopped, !suspending, !token.isCancelled else { return }
                recordEstimate(
                    CleanerEstimateSnapshot(
                        scannedAt: now(),
                        reclaimableBytes: result.categories.reduce(0) { $0 + $1.sizeBytes },
                        categoryCount: result.categories.count))
            })
        else { return }
        estimateTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            token.cancel(); task.cancel()
        }
        if estimateToken === token { estimateToken = nil; estimateTask = nil }
    }

    private func recordEstimate(_ estimate: CleanerEstimateSnapshot) {
        latestEstimate = estimate
        if let data = try? JSONEncoder().encode(estimate), data.count <= 1_024 {
            defaults.set(data, forKey: Self.backgroundEstimateKey)
        }
        if !scanned {
            try? ExtensionSharedState.current?.publish([
                "reclaimableBytes": String(estimate.reclaimableBytes)
            ])
        }
    }

    func stopBackgroundEstimates() {
        backgroundEstimates?.cancel()
        estimateToken?.cancel()
        estimateTask?.cancel()
        cancelScan()
    }

    func scan() {
        if remote { sendRemote("scan"); return }
        guard !scanning, !stopped, !suspending else { return }
        cancelScan()
        scanning = true
        operationTitle = "Scanning…"
        scanned = false
        logs = []
        logsExpanded = true
        previewToken = UUID()
        categories = []
        drives = []
        let token = CleanerCancellation()
        scanToken = token
        saveSelection()
        let stored = storedChoices
        workTask = track { [self, services] in
            defer { finish(token) }
            let all = await services.drives()
            guard owns(token), !token.isCancelled else { return }
            driveOptions = all
            drives = JunkScanner.drivesForScanning(all, selectedDriveIDs: driveSelection)
            let home = CleanerHome.url
            var roots = drives.map { $0.id == "/" ? home : URL(fileURLWithPath: $0.id) }
            roots += customFolders.filter { isDriveSelected($0) }.map {
                URL(fileURLWithPath: $0)
            }
            let updates = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let result = await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor [self] in
                    for await note in updates.stream {
                        guard owns(token), !token.isCancelled else { return }
                        log(note.hasPrefix("Scanning ") ? note : "Scanning \(note)…")
                    }
                }
                defer { updates.continuation.finish() }
                return await services.scan(roots, token) { note in
                    updates.continuation.yield(note)
                }
            }
            guard owns(token) else { return }
            if token.isCancelled {
                log("Cancelled.")
                return
            }
            previewToken = UUID()
            replaceSelection(CleanerSelection.resolve(result.categories, stored: stored))
            categories = result.categories
            for category in categories {
                log("  \(category.name) · \(JunkScanner.format(category.sizeBytes))")
            }
            log("Done · \(JunkScanner.format(reclaimableTotal)) reclaimable.")
            scanned = true
            scanning = false
            recordEstimate(
                CleanerEstimateSnapshot(
                    scannedAt: now(), reclaimableBytes: reclaimableTotal,
                    categoryCount: categories.count))
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            if owns(token), !token.isCancelled {
                withAnimation(.easeInOut(duration: 0.35)) { logsExpanded = false }
            }
        }
    }

    private func owns(_ token: CleanerCancellation) -> Bool {
        !stopped && !suspending && scanToken === token
    }

    private func finish(_ token: CleanerCancellation) {
        guard scanToken === token else { return }
        scanning = false
        cleaning = false
        scanToken = nil
        workTask = nil
    }

    private func log(_ line: String) {
        logs.append(line)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    func cancelScan() {
        if remote { sendRemote("cancel"); return }
        guard !cleaning else { return }
        scanToken?.cancel()
        workTask?.cancel()
    }

    var commandWork: Task<Void, Never>? { workTask }

    func commandCancellation() -> @Sendable () -> Void {
        let task = commandWork
        let cancellation = scanToken
        return {
            cancellation?.cancel(); task?.cancel()
        }
    }

    func finishWork() async { await workTask?.value }

    private func track(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !suspending, ownedTasks.count < 64 else { return nil }
        let id = UUID()
        let task = Task {
            defer { ownedTasks[id] = nil }
            await work()
        }
        ownedTasks[id] = task
        return task
    }

    func cancelPendingCommands() {
        selectionSave?.cancel()
        selectionSave = nil
        saveSelection()
        suspending = true
        remoteGeneration += 1
        stopBackgroundEstimates()
        scanToken?.cancel()
        driveTask?.cancel()
        driveOptionsLoad.cancel()
        for task in ownedTasks.values { task.cancel() }
    }

    func cancelAndWait() async {
        cancelPendingCommands()
        await backgroundEstimates?.value
        while let task = ownedTasks.values.first { await task.value }
    }

    func shutdown() async {
        guard !stopped else { await cancelAndWait(); return }
        stopped = true
        await cancelAndWait()
        stopBackgroundEstimates()
        await backgroundEstimates?.value
        backgroundEstimates = nil
        remoteGeneration += 1; remoteDrain?.cancel(); logCollapse?.cancel()
        await remoteDrain?.value; remoteDrain = nil
        remoteQueue.removeAll(); driveRequestInFlight = false
        cancelScan()
        driveTask?.cancel()
        driveOptionsLoad.cancel()
        await workTask?.value
        await driveTask?.value
        workTask = nil
        driveTask = nil
        scanToken = nil
        scanning = false
        categories = []
        drives = []
        driveOptions = []
        logs = []
    }

    func toggleAll(matching query: String? = nil) {
        guard !stopped, !suspending else { return }
        let query = (query ?? search).lowercased()
        defer { if remote { sendRemote("all", search: query) } }
        let scopes = index.scopes(matching: query)
        guard !scopes.isEmpty else { return }
        choose(index.selection(of: scopes) != .all, scopes: scopes)
    }

    func toggleCategory(_ id: String, matching query: String? = nil) {
        guard !stopped, !suspending else { return }
        let query = (query ?? search).lowercased()
        defer { if remote { sendRemote("category", value: id, search: query) } }
        guard let scope = index.scope(categoryID: id, matching: query) else { return }
        choose(index.selection(of: [scope]) != .all, scopes: [scope])
    }

    func toggleItem(categoryID: String, itemID: String) {
        guard !stopped, !suspending else { return }
        defer { if remote { sendRemote("item", value: categoryID, item: itemID) } }
        guard let position = index.position(categoryID: categoryID, itemID: itemID) else {
            return
        }
        let value = !index.marked[position]
        var updated = selection
        updated.choices[categoryID, default: CleanerCategoryChoice(selected: false)].set(
            itemID, to: value)
        commit(updated) { $0.set([position], to: value) }
    }

    private func choose(_ value: Bool, scopes: [CleanerSelectionScope]) {
        var updated = selection
        for scope in scopes {
            if scope.whole {
                updated.choices[scope.categoryID] = CleanerCategoryChoice(selected: value)
            } else {
                var choice =
                    updated.choices[scope.categoryID] ?? CleanerCategoryChoice(selected: false)
                for position in scope.positions { choice.set(index.ids[position], to: value) }
                updated.choices[scope.categoryID] = choice
            }
        }
        commit(updated) { $0.set(scopes.flatMap(\.positions), to: value) }
    }

    private func commit(
        _ updated: CleanerSelection, marking: (inout CleanerSelectionIndex) -> Void
    ) {
        marking(&index)
        selection = updated
        stats = index.stats
        selectionRevision &+= 1
        guard !remote else { return }
        selectionDirty = true
        guard selectionSave == nil else { return }
        selectionSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.selectionSave = nil
            self?.saveSelection()
        }
    }

    private func saveSelection() {
        guard selectionDirty, !remote else { return }
        selectionDirty = false
        var choices = storedChoices
        choices.merge(selection.choices) { $1 }
        if let data = try? JSONEncoder().encode(choices) {
            defaults.set(data, forKey: Self.selectionKey)
        }
    }

    private var storedChoices: [String: CleanerCategoryChoice] {
        guard let data = defaults.data(forKey: Self.selectionKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CleanerCategoryChoice].self, from: data)) ?? [:]
    }

    func toggleExpand(_ id: String) {
        guard !stopped, !suspending else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func clean(categoryID: String? = nil) {
        if remote { sendRemote("clean", value: categoryID); return }
        guard !scanning, !stopped, !suspending else { return }
        let items = CleanerOperationExecution.selectedItems(
            in: visibleCategories, categoryID: categoryID)
        saveSelection()
        guard !items.isEmpty else { return }
        cancelScan()
        scanning = true
        cleaning = true
        operationTitle = "Scanning…"
        let token = CleanerCancellation()
        scanToken = token
        workTask = track { [self, services] in
            let result = await services.clean(items, token)
            guard owns(token) else { return }
            lastReclaimed = result.reclaimedBytes
            finish(token)
            scan()
        }
    }
}
