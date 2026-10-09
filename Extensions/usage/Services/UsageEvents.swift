import Foundation

public enum UsageEvents {
    public static let limitsUpdated = Notification.Name("usage.limits.updated")
    public static let usageUpdated = Notification.Name("usage.document.updated")

    public static func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}
