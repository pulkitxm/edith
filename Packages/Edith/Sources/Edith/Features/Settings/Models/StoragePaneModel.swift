import EdithKit
import Foundation
import Observation

enum StorageCleanup: Sendable {
    case caches, logs
}

@MainActor
@Observable
final class StoragePaneModel {
    nonisolated static let retainedCacheNames: Set<String> = ["Runtime"]

    let load = ContentLoad()
    private(set) var inventory: StorageInventory?
    private(set) var measurement: StorageMeasurement?
    private(set) var cleaning: StorageCleanup?
    private(set) var removalError: String?
    private(set) var removalNotice: String?
    @ObservationIgnored private let clearCaches: @Sendable () throws -> Void
    @ObservationIgnored private let pruneLogs: @Sendable () throws -> Void

    init(
        clearCaches: @escaping @Sendable () throws -> Void = {
            try StoragePaneModel.clearCaches(at: DataRoot.caches)
        },
        pruneLogs: @escaping @Sendable () throws -> Void = { DataRoot.pruneLogs() }
    ) {
        self.clearCaches = clearCaches
        self.pruneLogs = pruneLogs
    }

    nonisolated static func clearCaches(at root: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        var failure: Error?
        for name in try fileManager.contentsOfDirectory(atPath: root.path)
        where !retainedCacheNames.contains(name) {
            do {
                try fileManager.removeItem(at: root.appendingPathComponent(name))
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }

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

    func clean(_ action: StorageCleanup) async {
        guard cleaning == nil else {
            removalError = "A cleanup is already running. Wait for it to finish and retry."
            return
        }
        cancelScan()
        cleaning = action
        removalError = nil
        removalNotice = nil
        defer { cleaning = nil }
        let work = action == .caches ? clearCaches : pruneLogs
        do {
            try await Task.detached(priority: .userInitiated) { try work() }.value
            removalNotice =
                action == .caches
                ? "Caches cleared. User data is retained. Refreshing measured storage."
                : "Logs older than seven days removed. Refreshing measured storage."
        } catch {
            removalError =
                (action == .caches
                    ? "Some caches could not be cleared. "
                    : "Some logs could not be removed. ") + error.localizedDescription
        }
    }
}
