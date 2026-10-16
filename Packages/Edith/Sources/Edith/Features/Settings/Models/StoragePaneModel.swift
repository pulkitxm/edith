import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class StoragePaneModel {
    let load = ContentLoad()
    private(set) var inventory: StorageInventory?
    private(set) var measurement: StorageMeasurement?
    private(set) var expanded: Set<String> = []
    private(set) var contents: [String: [StorageEntry]] = [:]
    private var contentTasks: [String: Task<Void, Never>] = [:]

    func refresh(
        inventory: StorageInventory,
        scan: @escaping @Sendable ([StorageScope]) async throws -> StorageMeasurement = {
            try StorageAccounting.scan(scopes: $0, isCancelled: { Task.isCancelled })
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

    func toggle(_ item: StorageItem) {
        if expanded.remove(item.id) != nil {
            contentTasks.removeValue(forKey: item.id)?.cancel()
            return
        }
        expanded.insert(item.id)
        if contents[item.id] == nil { loadContents(of: item) }
    }

    private func reloadContents() {
        for task in contentTasks.values { task.cancel() }
        contentTasks = [:]
        contents = [:]
        for item in inventory?.items ?? [] where expanded.contains(item.id) {
            loadContents(of: item)
        }
    }

    private func loadContents(of item: StorageItem) {
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
