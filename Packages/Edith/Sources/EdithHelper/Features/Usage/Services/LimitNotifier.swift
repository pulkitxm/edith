import EdithKit
import Foundation
import UserNotifications

@MainActor
final class LimitNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let defaults = UserDefaults.standard
    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
    }

    func evaluate(session: LimitWindow?, week: LimitWindow?) {
        let settings = NotifySettings.fromDefaults(SharedDefaults.store)
        guard settings.master else {
            cancelReminders()
            return
        }
        var state = loadState()
        let before = state
        let alerts = LimitNotifierLogic.decide(
            session: session, week: week, settings: settings, state: &state, now: Date())
        if state != before { save(state) }
        for alert in alerts { send(alert) }
        scheduleReminders(session: session, week: week, settings: settings)
    }

    func clearStateIfMasterOff() {
        guard !NotifySettings.fromDefaults(SharedDefaults.store).master else { return }
        for key in [
            "notifSessionLevel", "notifWeeklyLevel", "notifSessionPacing", "notifWeeklyPacing",
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    func cancelReminders() {
        center.removePendingNotificationRequests(withIdentifiers: [
            "reminder_session", "reminder_weekly",
        ])
    }

    func notifyTokenExpired() {
        let settings = NotifySettings.fromDefaults(SharedDefaults.store)
        guard settings.master, settings.tokenExpired else { return }
        if let last = defaults.object(forKey: "notifTokenExpiredAt") as? Date,
            Date().timeIntervalSince(last) < 3600
        {
            return
        }
        defaults.set(Date(), forKey: "notifTokenExpiredAt")
        send(
            LimitAlert(
                id: "token_expired",
                title: "Claude token expired", body: "Run claude to log in again"))
    }

    func sendTest() async -> String {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .denied:
            return "Blocked - enable Edith in System Settings > Notifications"
        case .notDetermined:
            PermissionPromptTracker.record()
            let granted =
                (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            IPC.post(IPC.Name.requestPermissionsRefresh)
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

    private func loadState() -> LimitNotifierState {
        var s = LimitNotifierState()
        s.sessionLevel =
            UsageLevel(rawValue: defaults.integer(forKey: "notifSessionLevel")) ?? .green
        s.weeklyLevel = UsageLevel(rawValue: defaults.integer(forKey: "notifWeeklyLevel")) ?? .green
        s.sessionPacing =
            PacingZone(rawValue: defaults.string(forKey: "notifSessionPacing") ?? "") ?? .onTrack
        s.weeklyPacing =
            PacingZone(rawValue: defaults.string(forKey: "notifWeeklyPacing") ?? "") ?? .onTrack
        return s
    }

    private func save(_ s: LimitNotifierState) {
        defaults.set(s.sessionLevel.rawValue, forKey: "notifSessionLevel")
        defaults.set(s.weeklyLevel.rawValue, forKey: "notifWeeklyLevel")
        defaults.set(s.sessionPacing.rawValue, forKey: "notifSessionPacing")
        defaults.set(s.weeklyPacing.rawValue, forKey: "notifWeeklyPacing")
    }

    private func send(_ alert: LimitAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        let id = alert.id
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error {
                NSLog("Edith notifications: add failed (%@): %@", id, error.localizedDescription)
            }
        }
    }

    private func scheduleReminders(
        session: LimitWindow?, week: LimitWindow?, settings: NotifySettings
    ) {
        center.removePendingNotificationRequests(withIdentifiers: [
            "reminder_session", "reminder_weekly",
        ])
        if settings.reminderSession,
            let fire = LimitNotifierLogic.reminderFireDate(
                reset: session?.resetsAt, offsetMinutes: settings.reminderSessionOffsetMin)
        {
            schedule(
                id: "reminder_session",
                title:
                    "Session resets in \(LimitNotifierLogic.offsetLabel(minutes: settings.reminderSessionOffsetMin))",
                body: "Save your spot or send it",
                at: fire)
        }
        if settings.reminderWeekly,
            let fire = LimitNotifierLogic.reminderFireDate(
                reset: week?.resetsAt, offsetMinutes: settings.reminderWeeklyOffsetMin)
        {
            schedule(
                id: "reminder_weekly",
                title:
                    "Weekly resets in \(LimitNotifierLogic.offsetLabel(minutes: settings.reminderWeeklyOffsetMin))",
                body: "Last lap on the cycle",
                at: fire)
        }
    }

    private func schedule(id: String, title: String, body: String, at fire: Date) {
        guard fire.timeIntervalSinceNow > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) {
            error in
            if let error {
                NSLog("Edith notifications: add failed (%@): %@", id, error.localizedDescription)
            }
        }
    }
}
