import Foundation

final class MaintenanceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

enum MaintenancePreferences {
    static let installDestination = "maintenance.installDestination"
    static let section = "maintenance.section"
    static let updateAutoRefresh = "maintenance.updateAutoRefresh"
    static let updateConcurrency = "maintenance.updateConcurrency"
    static let updateNotifications = "maintenance.updateNotifications"
    static let updateRefreshInterval = "maintenance.updateRefreshInterval"
    static let updateRetries = "maintenance.updateRetries"
}
