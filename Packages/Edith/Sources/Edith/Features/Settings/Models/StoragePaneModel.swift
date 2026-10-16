import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class StoragePaneModel {
    let load = ContentLoad()
    private(set) var inventory: StorageInventory?
    private(set) var measurement: StorageMeasurement?

    func refresh(
        inventory: StorageInventory,
        scan: @escaping @Sendable ([StorageScope]) async throws -> StorageMeasurement = {
            try StorageAccounting.scan(scopes: $0, isCancelled: { Task.isCancelled })
        }
    ) async {
        await load.perform(operation: { try await scan(inventory.scopes) }) { measurement in
            self.inventory = inventory
            self.measurement = measurement
        }
    }

    func cancelScan() { load.cancel() }
}
