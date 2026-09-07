import Foundation

public enum SidebarBadgeStore {
    public static let updatesAvailableKey = "sidebarUpdatesAvailable"
    public static let reclaimableBytesKey = "sidebarReclaimableBytes"
    public static let sessionsWorkingKey = "sidebarSessionsWorking"

    public static func recordUpdates(
        available: Int, defaults: UserDefaults = SharedDefaults.store
    ) {
        defaults.set(max(0, available), forKey: updatesAvailableKey)
    }

    public static func recordReclaimable(
        bytes: Int64, defaults: UserDefaults = SharedDefaults.store
    ) {
        defaults.set(max(0, bytes), forKey: reclaimableBytesKey)
    }

    public static func recordSessions(
        working: Int, defaults: UserDefaults = SharedDefaults.store
    ) {
        defaults.set(max(0, working), forKey: sessionsWorkingKey)
    }

    public static func updatesAvailable(_ defaults: UserDefaults = SharedDefaults.store) -> Int {
        defaults.integer(forKey: updatesAvailableKey)
    }

    public static func reclaimableBytes(_ defaults: UserDefaults = SharedDefaults.store) -> Int64 {
        Int64(defaults.integer(forKey: reclaimableBytesKey))
    }

    public static func sessionsWorking(_ defaults: UserDefaults = SharedDefaults.store) -> Int {
        defaults.integer(forKey: sessionsWorkingKey)
    }
}
