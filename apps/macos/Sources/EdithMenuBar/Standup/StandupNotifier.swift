import AppKit
import EdithKit
import UserNotifications

@MainActor
final class StandupNotifier {
    private static let categoryID = "standup"
    private static let copyAction = "standup.copy"
    private static let openAction = "standup.open"

    private var registered = false

    func send(text: String, date: Date) {
        registerCategoryIfNeeded()
        NotificationDelegateHub.shared.onAction = { [weak self] identifier, action in
            self?.handle(identifier: identifier, action: action, text: text)
        }
        let content = UNMutableNotificationContent()
        content.title = "Standup ready"
        content.body = text.count > 180 ? String(text.prefix(180)) + "…" : text
        content.categoryIdentifier = Self.categoryID
        content.sound = .default
        let identifier = "standup_\(StandupSchedule.dayKey(date))"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func handle(identifier: String, action: String, text: String) {
        guard identifier.hasPrefix("standup_") else { return }
        switch action {
        case Self.copyAction:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case Self.openAction:
            SharedDefaults.store.set("settings", forKey: "mainWindowSection")
            SharedDefaults.store.set("standup", forKey: "settingsSection")
            MainApp.openDashboard()
        default:
            break
        }
    }

    private func registerCategoryIfNeeded() {
        guard !registered else { return }
        registered = true
        let copy = UNNotificationAction(identifier: Self.copyAction, title: "Copy", options: [])
        let open = UNNotificationAction(
            identifier: Self.openAction, title: "Open", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: Self.categoryID, actions: [copy, open], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
