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
    private static let confirmedExternalPathsKey = "cleaner.confirmedExternalPaths"
    static let backgroundEstimateKey = "cleaner.backgroundEstimate"

    private(set) var previewToken = UUID()
    private(set) var categories: [JunkCategory] = [] {
        didSet {
            previewToken = UUID()
            try? ExtensionSharedState.current?.publish([
                "reclaimableBytes": String(reclaimableTotal)
            ])
        }
    }
    private(set) var scanning = false
    private(set) var scanned = false
    private(set) var logs: [String] = []
    var logsExpanded = false
    private(set) var lastReclaimed: Int64 = 0
    private(set) var drives: [DriveInfo] = []
    private(set) var driveOptions: [DriveInfo] = []
    let driveOptionsLoad = ContentLoad()
    var loadingDriveOptions: Bool { driveOptionsLoad.isRunning }
    private(set) var customFolders: [String] = []
    var search = ""
    private(set) var expanded: Set<String> = []
    private var driveSelection: Set<String>?
    private var scanToken: CleanerCancellation?
    private let defaults: UserDefaults
    private let services: CleanerServices
    private let now: @Sendable () -> Date
    private var backgroundEstimates: Task<Void, Never>?
    private(set) var latestEstimate: CleanerEstimateSnapshot?
    private var workTask: Task<Void, Never>?
    private var driveTask: Task<Void, Never>?
    private var engineClient: ExtensionEngineClient?
    private var remoteGeneration = 0
    private var remoteTask: Task<Void, Never>?
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
        let confirmed = Set(
            defaults.array(forKey: Self.confirmedExternalPathsKey) as? [String] ?? [])
        if let raw = defaults.array(forKey: "cleaner.selectedDrives") as? [String] {
            let kept = raw.filter { Self.pathIsAllowed($0, confirmed: confirmed) }
            driveSelection = Set(kept)
        }
        if let raw = defaults.array(forKey: "cleaner.customFolders") as? [String] {
            let kept = raw.filter { Self.pathIsAllowed($0, confirmed: confirmed) }
            customFolders = kept
        }
    }

    convenience init(engineClient: ExtensionEngineClient, defaults: UserDefaults) {
        self.init(defaults: defaults)
        self.engineClient = engineClient
    }

    var remote: Bool { engineClient != nil }

    func uiSnapshot() -> CleanerUISnapshot {
        .init(
            previewToken: previewToken, categories: categories, scanning: scanning,
            scanned: scanned,
            logs: logs, lastReclaimed: lastReclaimed, drives: drives, driveOptions: driveOptions,
            customFolders: customFolders, driveSelection: driveSelection,
            operationTitle: operationTitle)
    }

    func refreshRemote() async {
        guard let engineClient, !stopped, remoteTask == nil else { return }
        let generation = remoteGeneration
        do {
            let data = try await engineClient.invoke("cleaner.ui.snapshot")
            guard !stopped, !Task.isCancelled, generation == remoteGeneration else { return }
            applyRemote(try JSONDecoder().decode(CleanerUISnapshot.self, from: data))
        } catch is CancellationError {} catch { if !stopped { log(error.localizedDescription) } }
    }

    private func applyRemote(_ value: CleanerUISnapshot) {
        categories = value.categories; previewToken = value.previewToken
        scanning = value.scanning; scanned = value.scanned; logs = value.logs
        lastReclaimed = value.lastReclaimed; drives = value.drives;
        driveOptions = value.driveOptions
        customFolders = value.customFolders; driveSelection = value.driveSelection
        operationTitle = value.operationTitle
    }

    private func sendRemote(_ operation: String, value: String? = nil, item: String? = nil) {
        guard let engineClient, !stopped else { return }
        remoteTask?.cancel(); remoteGeneration += 1
        let generation = remoteGeneration
        let request = CleanerUIAction(
            operation: operation, value: value, item: item, previewToken: previewToken)
        remoteTask = Task {
            defer { if generation == remoteGeneration { remoteTask = nil } }
            do {
                let payload = try JSONEncoder().encode(request)
                let data = try await engineClient.invoke(
                    "cleaner.ui.action", payload: payload, timeout: 30)
                guard !stopped, !Task.isCancelled, generation == remoteGeneration else { return }
                applyRemote(try JSONDecoder().decode(CleanerUISnapshot.self, from: data))
            } catch is CancellationError {} catch {
                if !stopped, generation == remoteGeneration { log(error.localizedDescription) }
            }
        }
    }

    func addCustomFolder(_ path: String) {
        if remote { sendRemote("addFolder", value: path); return }
        guard !stopped else { return }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !customFolders.contains(standardizedPath) else { return }
        confirmExternalPathIfNeeded(standardizedPath)
        customFolders.append(standardizedPath)
        defaults.set(customFolders, forKey: "cleaner.customFolders")
        var selection = driveSelection ?? ["/"]
        selection.insert(standardizedPath)
        driveSelection = selection
        defaults.set(Array(selection), forKey: "cleaner.selectedDrives")
    }

    func removeCustomFolder(_ path: String) {
        if remote { sendRemote("removeFolder", value: path); return }
        guard !stopped else { return }
        customFolders.removeAll { $0 == path }
        defaults.set(customFolders, forKey: "cleaner.customFolders")
        driveSelection?.remove(path)
        if driveSelection != nil {
            defaults.set(Array(driveSelection ?? []), forKey: "cleaner.selectedDrives")
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
        if remote { sendRemote("drives"); return }
        guard !stopped else { return }
        driveTask?.cancel()
        driveTask = Task {
            await driveOptionsLoad.perform(operation: { [services] in await services.drives() }) {
                guard !stopped else { return }
                driveOptions = $0
            }
        }
    }

    func isDriveSelected(_ id: String) -> Bool {
        driveSelection?.contains(id) ?? (id == "/")
    }

    func toggleDrive(_ id: String) {
        if remote { sendRemote("drive", value: id); return }
        guard !stopped else { return }
        var selection = driveSelection ?? ["/"]
        if selection.contains(id) {
            selection.remove(id)
            if !customFolders.contains(id) { removeExternalConfirmation(id) }
        } else {
            confirmExternalPathIfNeeded(id)
            selection.insert(id)
        }
        driveSelection = selection
        defaults.set(Array(selection), forKey: "cleaner.selectedDrives")
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
        guard !stopped, !remote, backgroundEstimates == nil else { return }
        backgroundEstimates = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !stopped else { return }
                await estimateIfDue(onBattery: onBattery())
                do { try await delay(.seconds(60)) } catch { return }
            }
        }
    }

    func estimateIfDue(onBattery: Bool) async {
        guard !stopped, !remote, !Task.isCancelled, !onBattery, !scanning, workTask == nil,
            latestEstimate.map({ now().timeIntervalSince($0.scannedAt) < 604_800 }) != true
        else { return }
        scan(background: true)
        await withTaskCancellationHandler {
            await finishWork()
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelScan() }
        }
    }

    func stopBackgroundEstimates() {
        backgroundEstimates?.cancel()
        cancelScan()
    }

    func scan(background: Bool = false) {
        if remote { sendRemote("scan"); return }
        guard !scanning, !stopped else { return }
        cancelScan()
        scanning = true
        operationTitle = "Scanning…"
        scanned = false
        logs = []
        logsExpanded = true
        categories = []
        drives = []
        let token = CleanerCancellation()
        scanToken = token
        let choices = overrides
        let categoryChoices = categoryDefaults
        workTask = Task { [services] in
            defer { finish(token) }
            var roots: [URL] = []
            if !background {
                let all = await services.drives()
                guard owns(token), !token.isCancelled else { return }
                driveOptions = all
                drives = JunkScanner.drivesForScanning(all, selectedDriveIDs: driveSelection)
                let home = FileManager.default.homeDirectoryForCurrentUser
                roots = drives.map { $0.id == "/" ? home : URL(fileURLWithPath: $0.id) }
                roots += customFolders.filter { isDriveSelected($0) }.map {
                    URL(fileURLWithPath: $0)
                }
            }
            let result = await services.scan(roots, token) { [weak self = self] note in
                Task { @MainActor in
                    guard let self, self.owns(token), !token.isCancelled else { return }
                    self.log(note.hasPrefix("Scanning ") ? note : "Scanning \(note)…")
                }
            }
            guard owns(token) else { return }
            if token.isCancelled {
                log("Cancelled.")
                return
            }
            categories = result.categories.map {
                Self.applyChoices($0, items: choices, categories: categoryChoices)
            }
            for category in categories {
                log("  \(category.name) · \(JunkScanner.format(category.sizeBytes))")
            }
            log("Done · \(JunkScanner.format(reclaimableTotal)) reclaimable.")
            scanned = true
            scanning = false
            let estimate = CleanerEstimateSnapshot(
                scannedAt: now(), reclaimableBytes: reclaimableTotal,
                categoryCount: categories.count)
            latestEstimate = estimate
            if let data = try? JSONEncoder().encode(estimate), data.count <= 1_024 {
                defaults.set(data, forKey: Self.backgroundEstimateKey)
            }
            guard !background else { return }
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            if owns(token), !token.isCancelled {
                withAnimation(.easeInOut(duration: 0.35)) { logsExpanded = false }
            }
        }
    }

    private func owns(_ token: CleanerCancellation) -> Bool { !stopped && scanToken === token }

    private func finish(_ token: CleanerCancellation) {
        guard scanToken === token else { return }
        scanning = false
        scanToken = nil
        workTask = nil
    }

    private func log(_ line: String) {
        logs.append(line)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    func cancelScan() {
        if remote { sendRemote("cancel"); return }
        scanToken?.cancel()
        workTask?.cancel()
    }

    func finishWork() async { await workTask?.value }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        stopBackgroundEstimates()
        await backgroundEstimates?.value
        backgroundEstimates = nil
        remoteGeneration += 1; remoteTask?.cancel()
        await remoteTask?.value; remoteTask = nil
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
        if remote { sendRemote("all"); return }
        guard !stopped else { return }
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
        if remote { sendRemote("category", value: id); return }
        guard !stopped else { return }
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
        if remote { sendRemote("item", value: categoryID, item: itemID); return }
        guard !stopped else { return }
        guard let categoryIndex = categories.firstIndex(where: { $0.id == categoryID }),
            let itemIndex = categories[categoryIndex].items.firstIndex(where: { $0.id == itemID })
        else { return }
        categories[categoryIndex].items[itemIndex].selected.toggle()
        var choices = overrides
        choices[itemID] = categories[categoryIndex].items[itemIndex].selected
        overrides = choices
    }

    func toggleExpand(_ id: String) {
        guard !stopped else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func clean(categoryID: String? = nil) {
        if remote { sendRemote("clean", value: categoryID); return }
        guard !scanning, !stopped else { return }
        let items = CleanerOperationExecution.selectedItems(in: categories, categoryID: categoryID)
        guard !items.isEmpty else { return }
        cancelScan()
        scanning = true
        operationTitle = "Cleaning…"
        let token = CleanerCancellation()
        scanToken = token
        workTask = Task { [services] in
            let result = await services.clean(items, token)
            guard owns(token) else { return }
            lastReclaimed = result.reclaimedBytes
            finish(token)
            if !token.isCancelled { scan() }
        }
    }

    private var overrides: [String: Bool] {
        get {
            (defaults.dictionary(forKey: "cleaner.selectionOverrides") ?? [:])
                .compactMapValues { $0 as? Bool }
        }
        set { defaults.set(newValue, forKey: "cleaner.selectionOverrides") }
    }

    private var categoryDefaults: [String: Bool] {
        get {
            (defaults.dictionary(forKey: "cleaner.categoryDefaults") ?? [:])
                .compactMapValues { $0 as? Bool }
        }
        set { defaults.set(newValue, forKey: "cleaner.categoryDefaults") }
    }
}
