import EdithExtensionUI
import Foundation
import UserNotifications

@MainActor
final class LimitNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LimitNotifier()
    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
    }

    func sendTest() async -> String {
        guard !Task.isCancelled else { return "Cancelled" }
        let status = await center.notificationSettings().authorizationStatus
        guard !Task.isCancelled else { return "Cancelled" }
        switch status {
        case .denied:
            return "Blocked - enable Edith in System Settings > Notifications"
        case .notDetermined:
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            try? await Task.sleep(for: .seconds(1))
            let refreshed = await center.notificationSettings().authorizationStatus
            guard !Task.isCancelled else { return "Cancelled" }
            let granted = refreshed == .authorized || refreshed == .provisional
            guard granted else { return "Permission not granted" }
        default:
            break
        }
        guard !Task.isCancelled else { return "Cancelled" }
        let id = "usage.test_\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        content.title = "Hey, you're set"
        content.body = "If you see this, notifications work"
        content.sound = .default
        do {
            try await center.add(
                UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return "Cancelled"
        }
        let delivered = await center.deliveredNotifications().contains {
            $0.request.identifier == id
        }
        return delivered ? "Delivered" : "Sent but not delivered - check Focus / System Settings"
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            response.notification.request.content.userInfo["extensionID"] as? String == "usage"
        else { return }
        await MainActor.run { ExtensionPresentation.showWindow() }
    }

    func shutdown() {
        if center.delegate === self { center.delegate = nil }
    }
}
