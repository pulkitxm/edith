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
        public static let settingsChanged = Notification.Name("com.pulkit.edith.settingsChanged")
        public static let requestPermissionsRefresh = Notification.Name(
            "com.pulkit.edith.requestPermissionsRefresh")
        public static let grantCalendar = Notification.Name("com.pulkit.edith.grantCalendar")
        public static let grantNotifications = Notification.Name(
            "com.pulkit.edith.grantNotifications")
        public static let grantAccessibility = Notification.Name(
            "com.pulkit.edith.grantAccessibility")
        public static let grantInputMonitoring = Notification.Name(
            "com.pulkit.edith.grantInputMonitoring")
        public static let grantFullDisk = Notification.Name("com.pulkit.edith.grantFullDisk")
        public static let grantScreenRecording = Notification.Name(
            "com.pulkit.edith.grantScreenRecording")
        public static let requestTestNotification = Notification.Name(
            "com.pulkit.edith.requestTestNotification")
        public static let presenterAutoActiveChanged = Notification.Name(
            "com.pulkit.edith.presenterAutoActiveChanged")
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
