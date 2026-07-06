import Foundation

public enum IPC {
    public enum Name {
        public static let requestUsageRefresh = Notification.Name(
            "com.pulkit.edith.requestUsageRefresh")
        public static let usageRefreshStarted = Notification.Name(
            "com.pulkit.edith.usageRefreshStarted")
        public static let usageRefreshFinished = Notification.Name(
            "com.pulkit.edith.usageRefreshFinished")
        public static let quitMainApp = Notification.Name("com.pulkit.edith.quitMainApp")
    }

    public static func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    public static func observe(_ name: Notification.Name, using block: @escaping () -> Void)
        -> NSObjectProtocol
    {
        DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { _ in block() }
    }

    public static func stopObserving(_ token: NSObjectProtocol) {
        DistributedNotificationCenter.default().removeObserver(token)
    }
}
