import Foundation

enum NotchAlertPriority: Int, Comparable, Sendable {
    case low, medium, high, critical
    static func < (lhs: NotchAlertPriority, rhs: NotchAlertPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct NotchAlert: Equatable, Identifiable, Sendable {
    let id: String
    let icon: String
    let tint: String
    let title: String
    let subtitle: String?
    let priority: NotchAlertPriority
    let autoHide: TimeInterval

    init(
        id: String, icon: String, tint: String = "#e0a83f", title: String, subtitle: String? = nil,
        priority: NotchAlertPriority = .medium, autoHide: TimeInterval = 3
    ) {
        self.id = id
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.priority = priority
        self.autoHide = autoHide
    }
}

enum NotchAlertLogic {
    static func shouldPreempt(current: NotchAlert?, incoming: NotchAlert) -> Bool {
        guard let current else { return true }
        if current.id == incoming.id { return true }
        return incoming.priority >= current.priority
    }
}
