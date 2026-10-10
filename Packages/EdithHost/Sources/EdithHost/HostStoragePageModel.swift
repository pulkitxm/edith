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
    private(set) var removingID: String?
    private(set) var removalError: String?
    private(set) var removalNotice: String?

    func refresh(
        inventory: HostStorageInventory,
        scan: @escaping @Sendable ([HostStorageScope]) async throws -> HostStorageMeasurement = {
            try HostStorageAccounting.scan(scopes: $0, isCancelled: { Task.isCancelled })
        }
    ) async {
        await load.perform(operation: { try await scan(inventory.scopes) }) { measurement in
            self.inventory = inventory
            self.measurement = measurement
        }
    }

    func cancelScan() { load.cancel() }

    func remove(id: String, marketplace: HostMarketplace) async {
        guard removingID == nil, marketplace.operationID == nil else {
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
        await marketplace.remove(id: id)
        removalError = marketplace.error
        if removalError == nil {
            removalNotice =
                marketplace.pendingRemovalIDs.contains(id)
                ? "Removal is pending while a package is in use. Its files still count as storage."
                : "Extension packages removed. Extension user data is retained. Refreshing measured storage."
        }
    }
}
