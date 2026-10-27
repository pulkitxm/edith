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
    private static let selectionOverridesKey = "cleanerSelectionOverrides"
    private static let categoryDefaultsKey = "cleanerCategoryDefaults"
    static let backgroundEstimateKey = "cleaner.backgroundEstimate"

    private(set) var previewToken = UUID()
    private(set) var categories: [JunkCategory] = [] {
        didSet {
            try? ExtensionSharedState.current?.publish([
                "reclaimableBytes": String(reclaimableTotal)
            ])
        }
    }
    private(set) var scanning = false
    private(set) var scanned = false
    private(set) var logs: [String] = []
    var logsExpanded = false {
        didSet { rememberUIState() }
    }
    private(set) var lastReclaimed: Int64 = 0
    private(set) var drives: [DriveInfo] = []
    private(set) var driveOptions: [DriveInfo] = []
    let driveOptionsLoad = ContentLoad()
    var loadingDriveOptions: Bool {
        remote ? remoteLoadingDriveOptions || driveRequestInFlight : driveOptionsLoad.isRunning
    }
    private var remoteLoadingDriveOptions = false
    private var driveRequestInFlight = false
    private(set) var customFolders: [String] = []
    var search = "" {
        didSet { rememberUIState() }
    }
    private(set) var expanded: Set<String> = [] {
        didSet { rememberUIState() }
    }
    private var driveSelection: Set<String>?
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
    private(set) var operationTitle = "Scanning…"

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
    }

    convenience init(engineClient: ExtensionEngineClient, defaults: UserDefaults) {
        self.init(defaults: defaults)
        self.engineClient = engineClient
        if let memory = Self.uiMemory {
            seed(memory.snapshot)
            logsExpanded = memory.logsExpanded
            search = memory.search
            expanded = memory.expanded
        }
    }

    struct UIMemory {
        var snapshot: CleanerUISnapshot
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
            operationTitle: operationTitle, loadingDriveOptions: driveOptionsLoad.isRunning)
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
            let data = try await engineClient.invoke("cleaner.ui.snapshot")
            guard !stopped, !suspending, !Task.isCancelled, generation == remoteGeneration else {
                return
            }
            applyRemote(try JSONDecoder().decode(CleanerUISnapshot.self, from: data))
        } catch is CancellationError {} catch {
            if !stopped, !suspending { log(error.localizedDescription) }
        }
    }

    private func seed(_ value: CleanerUISnapshot) {
        categories = value.categories; previewToken = value.previewToken
        scanning = value.scanning; scanned = value.scanned; logs = value.logs
        lastReclaimed = value.lastReclaimed; drives = value.drives
        driveOptions = value.driveOptions
        customFolders = value.customFolders; driveSelection = value.driveSelection
        operationTitle = value.operationTitle
        remoteLoadingDriveOptions = value.loadingDriveOptions
    }

    private func applyRemote(_ value: CleanerUISnapshot) {
        let wasScanning = scanning
        seed(value)
        Self.uiMemory = UIMemory(
            snapshot: value, logsExpanded: logsExpanded, search: search, expanded: expanded)
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

    private func sendRemote(_ operation: String, value: String? = nil, item: String? = nil) {
        guard engineClient != nil, !stopped, !suspending, remoteQueue.count < 64 else { return }
        remoteGeneration += 1
        remoteQueue.append(
            CleanerUIAction(
                operation: operation, value: value, item: item, previewToken: previewToken))
        guard remoteDrain == nil else { return }
        remoteDrain = track { [self] in
            defer { remoteDrain = nil }
            guard let engineClient else { return }
            var latest: CleanerUISnapshot?
            while !remoteQueue.isEmpty {
                let request = remoteQueue.removeFirst()
                do {
                    let payload = try JSONEncoder().encode(request)
                    let data = try await engineClient.invoke(
                        "cleaner.ui.action", payload: payload, timeout: 30)
                    guard !stopped, !suspending, !Task.isCancelled else { return }
                    latest = try JSONDecoder().decode(CleanerUISnapshot.self, from: data)
                } catch is CancellationError {
                    return
                } catch {
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

    var reclaimableTotal: Int64 { categories.reduce(0) { $0 + $1.sizeBytes } }
    var selectedTotal: Int64 {
        CleanerOperationExecution.selectedItems(in: categories).reduce(0) { $0 + $1.sizeBytes }
    }

    var totalItemCount: Int { categories.reduce(0) { $0 + $1.items.count } }
    var selectedItemCount: Int {
        CleanerOperationExecution.selectedItems(in: categories).count
    }

    func selectedTotal(categoryID: String) -> Int64 {
        CleanerOperationExecution.selectedItems(in: categories, categoryID: categoryID)
            .reduce(0) { $0 + $1.sizeBytes }
    }

    func selectedItemCount(categoryID: String) -> Int {
        CleanerOperationExecution.selectedItems(in: categories, categoryID: categoryID).count
    }

    var overallSelection: JunkSelection {
        let total = totalItemCount
        guard total > 0 else { return .none }
        let selected = selectedItemCount
        if selected == 0 { return .none }
        if selected == total { return .all }
        return .some
    }

    var filteredCategories: [JunkCategory] {
        guard !search.isEmpty else { return categories }
        let query = search.lowercased()
        return categories.compactMap { category in
            if category.name.lowercased().contains(query) { return category }
            let items = category.items.filter { $0.name.lowercased().contains(query) }
            guard !items.isEmpty else { return nil }
            var trimmed = category
            trimmed.items = items
            return trimmed
        }
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
        let choices = overrides
        let categoryChoices = categoryDefaults
        workTask = track { [self, services] in
            defer { finish(token) }
            let all = await services.drives()
            guard owns(token), !token.isCancelled else { return }
            driveOptions = all
            drives = JunkScanner.drivesForScanning(all, selectedDriveIDs: driveSelection)
            let home = FileManager.default.homeDirectoryForCurrentUser
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
            categories = result.categories.map {
                Self.applyChoices($0, items: choices, categories: categoryChoices)
            }
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

    private static func applyChoices(
        _ category: JunkCategory, items itemChoices: [String: Bool],
        categories categoryChoices: [String: Bool]
    ) -> JunkCategory {
        var updated = category
        let categoryDefault = categoryChoices[category.id]
        updated.items = category.items.map { item in
            var copy = item
            if let choice = itemChoices[item.id] {
                copy.selected = choice
            } else if let categoryDefault {
                copy.selected = categoryDefault
            }
            return copy
        }
        return updated
    }

    func toggleAll() {
        guard !stopped, !suspending else { return }
        defer { if remote { sendRemote("all") } }
        let selectAll = overallSelection != .all
        var itemChoices = overrides
        var categoryChoices = categoryDefaults
        for index in categories.indices {
            categoryChoices[categories[index].id] = selectAll
            for item in categories[index].items { itemChoices[item.id] = nil }
            for item in categories[index].items.indices {
                categories[index].items[item].selected = selectAll
            }
        }
        overrides = itemChoices
        categoryDefaults = categoryChoices
    }

    func toggleCategory(_ id: String) {
        guard !stopped, !suspending else { return }
        defer { if remote { sendRemote("category", value: id) } }
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
        let selectAll = categories[index].selection != .all
        var itemChoices = overrides
        for item in categories[index].items {
            itemChoices[item.id] = nil
        }
        overrides = itemChoices
        var categoryChoices = categoryDefaults
        categoryChoices[id] = selectAll
        categoryDefaults = categoryChoices
        for item in categories[index].items.indices {
            categories[index].items[item].selected = selectAll
        }
    }

    func toggleItem(categoryID: String, itemID: String) {
        guard !stopped, !suspending else { return }
        defer { if remote { sendRemote("item", value: categoryID, item: itemID) } }
        guard let categoryIndex = categories.firstIndex(where: { $0.id == categoryID }),
            let itemIndex = categories[categoryIndex].items.firstIndex(where: { $0.id == itemID })
        else { return }
        categories[categoryIndex].items[itemIndex].selected.toggle()
        var choices = overrides
        choices[itemID] = categories[categoryIndex].items[itemIndex].selected
        overrides = choices
    }

    func toggleExpand(_ id: String) {
        guard !stopped, !suspending else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func clean(categoryID: String? = nil) {
        if remote { sendRemote("clean", value: categoryID); return }
        guard !scanning, !stopped, !suspending else { return }
        let items = CleanerOperationExecution.selectedItems(in: categories, categoryID: categoryID)
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

    private var overrides: [String: Bool] {
        get {
            (defaults.dictionary(forKey: Self.selectionOverridesKey) ?? [:])
                .compactMapValues { $0 as? Bool }
        }
        set { if !remote { defaults.set(newValue, forKey: Self.selectionOverridesKey) } }
    }

    private var categoryDefaults: [String: Bool] {
        get {
            (defaults.dictionary(forKey: Self.categoryDefaultsKey) ?? [:])
                .compactMapValues { $0 as? Bool }
        }
        set { if !remote { defaults.set(newValue, forKey: Self.categoryDefaultsKey) } }
    }
}
