import EdithExtensionSupport
import Foundation

enum NotchAlertPriority: Int, Comparable, Sendable, Codable {
    case low, medium, high, critical
    static func < (lhs: NotchAlertPriority, rhs: NotchAlertPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct NotchAlert: Equatable, Identifiable, Sendable, Codable {
    let id: String
    let icon: String
    let tint: String
    let title: String
    let subtitle: String?
    let priority: NotchAlertPriority
    let autoHide: TimeInterval
    let settingsTab: String?

    init(
        id: String, icon: String, tint: String = "#e0a83f", title: String, subtitle: String? = nil,
        priority: NotchAlertPriority = .medium, autoHide: TimeInterval = 3,
        settingsTab: String? = nil
    ) {
        self.id = id
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.priority = priority
        self.autoHide = autoHide
        self.settingsTab = settingsTab
    }
}

extension NotchAlert {
    static func updateReady(version: String) -> NotchAlert {
        NotchAlert(
            id: "update.ready", icon: "arrow.down.circle.fill", tint: "#7bb08a",
            title: "Edith \(version) is ready", subtitle: "Quit and reopen to finish",
            priority: .high, autoHide: 8, settingsTab: "updates")
    }

    static let permissionHint = NotchAlert(
        id: "permissions.hint", icon: "hand.raised.fill",
        title: "Grant access in one place",
        subtitle: "Settings > Permissions lists every one", priority: .high,
        autoHide: 6, settingsTab: "permissions")

    static func hostAlert(from info: [AnyHashable: Any]) -> NotchAlert? {
        switch info["kind"] as? String {
        case "permissionHint": return permissionHint
        case "updateReady":
            guard let version = info["version"] as? String, !version.isEmpty,
                version.count <= 64
            else { return nil }
            return updateReady(version: version)
        default: return nil
        }
    }
}

struct PendingNotchAlert: Equatable, Sendable {
    let alert: NotchAlert
    let at: Date
}

struct PowerSnapshot: Equatable, Sendable {
    var onAC: Bool?
    var charging: Bool?
    var capacity: Int?
}

enum NotchAlertLogic {
    static let pendingLimit = 3
    static let pendingTTL: TimeInterval = 60

    static func shouldPreempt(current: NotchAlert?, incoming: NotchAlert) -> Bool {
        guard let current else { return true }
        if current.id == incoming.id { return true }
        return incoming.priority >= current.priority
    }

    static func queue(
        _ pending: [PendingNotchAlert], adding alert: NotchAlert, at date: Date
    ) -> [PendingNotchAlert] {
        var out = pending.filter { $0.alert.id != alert.id }
        out.append(PendingNotchAlert(alert: alert, at: date))
        if out.count > pendingLimit { out.removeFirst(out.count - pendingLimit) }
        return out
    }

    static func dequeue(
        _ pending: [PendingNotchAlert], now: Date
    ) -> (next: NotchAlert?, rest: [PendingNotchAlert]) {
        let cutoff = now.addingTimeInterval(-pendingTTL)
        var fresh = pending.filter { $0.at >= cutoff }
        guard fresh.isEmpty == false else { return (nil, []) }
        let next = fresh.removeFirst()
        return (next.alert, fresh)
    }

    static func powerAlerts(
        now: PowerSnapshot, lastOnAC: Bool?, lastCapacity: Int?
    ) -> [NotchAlert] {
        var out: [NotchAlert] = []
        if let onAC = now.onAC, onAC != lastOnAC {
            let subtitle = now.capacity.map { "\($0)%" }
            if onAC {
                out.append(
                    NotchAlert(
                        id: "power.charging", icon: "bolt.fill", tint: "#4cc47e",
                        title: now.charging == true ? "Charging" : "Plugged in",
                        subtitle: subtitle, priority: .low, autoHide: 2.5))
            } else {
                out.append(
                    NotchAlert(
                        id: "power.charging", icon: "bolt.slash.fill", tint: "#e0a83f",
                        title: "On battery", subtitle: subtitle, priority: .low, autoHide: 2.5))
            }
        }
        if let capacity = now.capacity, let last = lastCapacity, capacity <= 20, last > 20 {
            out.append(
                NotchAlert(
                    id: "battery.low", icon: "battery.25", tint: "#e0664f", title: "Battery low",
                    subtitle: "\(capacity)%", priority: .high, autoHide: 4))
        }
        return out
    }
}
