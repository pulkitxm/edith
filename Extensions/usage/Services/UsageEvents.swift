import Foundation

public enum UsageEvents {
    public static let limitsUpdated = Notification.Name("usage.limits.updated")
    public static let usageUpdated = Notification.Name("usage.document.updated")

    public static let refreshStarted = Notification.Name("usage.refresh.started")
    public static let refreshFinished = Notification.Name("usage.refresh.finished")

    @MainActor
    public static func observe(_ name: Notification.Name, handler: @escaping @MainActor () -> Void)
        -> NSObjectProtocol
    {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    public static func stopObserving(_ token: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(token)
    }

    public static func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}
