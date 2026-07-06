import UserNotifications

@MainActor
public final class NotificationDelegateHub: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationDelegateHub()
    public var onAction: ((String, String) -> Void)?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        await MainActor.run { NotificationDelegateHub.shared.onAction?(identifier, action) }
    }
}
