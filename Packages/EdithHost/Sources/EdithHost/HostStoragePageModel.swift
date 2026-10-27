import EdithExtensionUI
import EdithHostCore
import Foundation
import Observation

@MainActor
@Observable
final class HostStoragePageModel {
    let load = ContentLoad()
    private(set) var inventory: HostStorageInventory?
    private(set) var measurement: HostStorageMeasurement?
    private(set) var expanded: Set<String> = []
    private(set) var contents: [String: [HostStorageEntry]] = [:]
    private(set) var removingID: String?
    private(set) var removalError: String?
    private(set) var removalNotice: String?
    private var contentTasks: [String: Task<Void, Never>] = [:]

    func refresh(
        inventory: HostStorageInventory,
        scan: @escaping @Sendable ([HostStorageScope]) async throws -> HostStorageMeasurement = {
            try HostStorageAccounting.scan(scopes: $0, isCancelled: { Task.isCancelled })
        }
    ) async {
        await load.perform(operation: { try await scan(inventory.scopes) }) { measurement in
            self.inventory = inventory
            self.measurement = measurement
            self.reloadContents()
        }
    }

    func cancelScan() {
        load.cancel()
        for task in contentTasks.values { task.cancel() }
        contentTasks = [:]
    }

    func toggle(_ item: HostStorageItem) {
        if expanded.remove(item.id) != nil {
            contentTasks.removeValue(forKey: item.id)?.cancel()
            return
        }
        expanded.insert(item.id)
        if contents[item.id] == nil { loadContents(of: item) }
    }

    func remove(id: String, marketplace: HostMarketplace) async {
        guard removingID == nil, !marketplace.isBusy(id) else {
            removalError =
                "An extension operation is already running. Wait for it to finish and retry."
            return
        }
        guard marketplace.installedVersions[id]?.isEmpty == false else {
            removalError = "This package is no longer installed. Refresh the storage scan."
            return
        }
        cancelScan()
        removingID = id
        removalError = nil
        removalNotice = nil
        defer { removingID = nil }
        removalError = await marketplace.remove(id: id)
        if removalError == nil {
            removalNotice =
                marketplace.pendingRemovalIDs.contains(id)
                ? "Removal is pending while a package is in use. Its files still count as storage."
                : "Extension packages removed. Extension user data is retained. Refreshing measured storage."
        }
    }

    private func reloadContents() {
        for task in contentTasks.values { task.cancel() }
        contentTasks = [:]
        contents = [:]
        for item in inventory?.items ?? [] where expanded.contains(item.id) {
            loadContents(of: item)
        }
    }

    private func loadContents(of item: HostStorageItem) {
        guard let inventory else { return }
        contentTasks[item.id]?.cancel()
        contentTasks[item.id] = Task {
            let work = Task.detached(priority: .userInitiated) {
                (try? inventory.contents(of: item, isCancelled: { Task.isCancelled })) ?? []
            }
            let entries = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled else { return }
            contents[item.id] = entries
            contentTasks[item.id] = nil
        }
    }
}
