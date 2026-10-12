import AppKit
import Foundation

final class CodeStatsVolumeWatch: @unchecked Sendable {
    static let names: [Notification.Name] = [
        NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
    ]

    private let center: NotificationCenter
    private let lock = NSLock()
    private var tokens: [any NSObjectProtocol] = []

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
    }

    func start(_ changed: @escaping @Sendable () -> Void) {
        let added = Self.names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in changed() }
        }
        lock.withLock { tokens.append(contentsOf: added) }
    }

    func stop() {
        let removed = lock.withLock {
            let current = tokens
            tokens.removeAll()
            return current
        }
        for token in removed { center.removeObserver(token) }
    }
}
