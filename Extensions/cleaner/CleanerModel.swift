import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Observation
import SwiftUI

@MainActor
@Observable
final class CleanerModel {
    private static let confirmedExternalPathsKey = "cleaner.confirmedExternalPaths"

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
    private var workTask: Task<Void, Never>?
    private var driveTask: Task<Void, Never>?
    private var stopped = false
    private(set) var operationTitle = "Scanning…"

    init(
        scanned: Bool = false, defaults: UserDefaults = SharedDefaults.store,
        services: CleanerServices = CleanerServices()
    ) {
        self.defaults = defaults
        self.services = services
        self.scanned = scanned
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

    func addCustomFolder(_ path: String) {
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

    func scan() {
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
            let all = await services.drives()
            guard owns(token), !token.isCancelled else { return }
            driveOptions = all
            drives = JunkScanner.drivesForScanning(all, selectedDriveIDs: driveSelection)
            let home = FileManager.default.homeDirectoryForCurrentUser
            var roots = drives.map { $0.id == "/" ? home : URL(fileURLWithPath: $0.id) }
            roots += customFolders.filter { isDriveSelected($0) }.map { URL(fileURLWithPath: $0) }
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
        scanToken?.cancel()
        workTask?.cancel()
    }

    func finishWork() async { await workTask?.value }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
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
