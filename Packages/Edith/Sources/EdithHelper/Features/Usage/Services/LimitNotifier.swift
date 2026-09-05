import EdithKit
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
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .denied:
            return "Blocked - enable Edith in System Settings > Notifications"
        case .notDetermined:
            await MainActor.run { PermissionsModel.shared.request(.notifications) }
            try? await Task.sleep(for: .seconds(1))
            let refreshed = await center.notificationSettings().authorizationStatus
            let granted = refreshed == .authorized || refreshed == .provisional
            guard granted else { return "Permission not granted" }
        default:
            break
        }
        let id = "test_\(UUID().uuidString)"
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

}
