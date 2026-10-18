import EdithExtensionSupport
import Foundation

final class MaintenanceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

enum MaintenancePreferences {
    static let installDestination = AppStorageKeys.AppMaintenance.installDestination
    static let section = AppStorageKeys.AppMaintenance.section
    static let updateAutoRefresh = AppStorageKeys.AppMaintenance.updateAutoRefresh
    static let updateConcurrency = AppStorageKeys.AppMaintenance.updateConcurrency
    static let updateNotifications = AppStorageKeys.AppMaintenance.updateNotifications
    static let updateRefreshInterval = AppStorageKeys.AppMaintenance.updateRefreshInterval
    static let updateRetries = AppStorageKeys.AppMaintenance.updateRetries
}
