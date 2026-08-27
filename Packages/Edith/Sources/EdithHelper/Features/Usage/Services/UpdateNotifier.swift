import EdithKit
import Foundation

enum UpdateNotifier {
    static let identifier = "update_ready"

    static func title(for version: String) -> String {
        "Edith \(version) is ready"
    }

    static let body = "Quit and reopen Edith to finish updating."

    static func version(from info: [AnyHashable: Any]) -> String? {
        guard let version = info["version"] as? String, !version.isEmpty else { return nil }
        return version
    }

    static func alert(for version: String) -> NotchAlert {
        NotchAlert(
            id: "update.ready", icon: "arrow.down.circle.fill", tint: "#7bb08a",
            title: title(for: version), subtitle: "Quit and reopen to finish",
            priority: .high, autoHide: 8, settingsTab: "updates")
    }

    static func notify(
        version: String, queue: NotificationReplacementQueue = .shared
    ) {
        queue.submit(
            NotificationReplacement(
                identifier: identifier, title: title(for: version), body: body,
                failureContext: "Edith notifications: update nudge failed"))
    }
}
