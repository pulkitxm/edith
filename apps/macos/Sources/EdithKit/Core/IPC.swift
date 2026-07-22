import Foundation

public enum IPC {
    public enum Name {
        public static let requestUsageRefresh = Notification.Name(
            "com.pulkit.edith.requestUsageRefresh")
        public static let usageRefreshStarted = Notification.Name(
            "com.pulkit.edith.usageRefreshStarted")
        public static let usageRefreshFinished = Notification.Name(
            "com.pulkit.edith.usageRefreshFinished")
        public static let requestLimitsRefresh = Notification.Name(
            "com.pulkit.edith.requestLimitsRefresh")
        public static let limitsUpdated = Notification.Name("com.pulkit.edith.limitsUpdated")
        public static let quitMainApp = Notification.Name("com.pulkit.edith.quitMainApp")
        public static let settingsChanged = Notification.Name("com.pulkit.edith.settingsChanged")
        public static let requestPermissionsRefresh = Notification.Name(
            "com.pulkit.edith.requestPermissionsRefresh")
        public static let permissionsRefreshed = Notification.Name(
            "com.pulkit.edith.permissionsRefreshed")
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
        public static let grantCamera = Notification.Name("com.pulkit.edith.grantCamera")
        public static let requestTestNotification = Notification.Name(
            "com.pulkit.edith.requestTestNotification")
        public static let clipboardChanged = Notification.Name("com.pulkit.edith.clipboardChanged")
        public static let presenterAutoActiveChanged = Notification.Name(
            "com.pulkit.edith.presenterAutoActiveChanged")
        public static let musicCommand = Notification.Name("com.pulkit.edith.musicCommand")
        public static let musicState = Notification.Name("com.pulkit.edith.musicState")
        public static let requestMusicState = Notification.Name(
            "com.pulkit.edith.requestMusicState")
        public static let musicLevel = Notification.Name("com.pulkit.edith.musicLevel")
        public static let requestMusicLevels = Notification.Name(
            "com.pulkit.edith.requestMusicLevels")
        public static let requestKeyboardClean = Notification.Name(
            "com.pulkit.edith.requestKeyboardClean")
        public static let openPanel = Notification.Name("com.pulkit.edith.openPanel")
        public static let permissionHintDue = Notification.Name(
            "com.pulkit.edith.permissionHintDue")
        public static let musicFolderChanged = Notification.Name(
            "com.pulkit.edith.musicFolderChanged")
        public static let musicFavouritesChanged = Notification.Name(
            "com.pulkit.edith.musicFavouritesChanged")
        public static let musicRevealFolder = Notification.Name(
            "com.pulkit.edith.musicRevealFolder")
        public static let presenterPauseAuto = Notification.Name(
            "com.pulkit.edith.presenterPauseAuto")
    }

    public static func post(_ name: Notification.Name, userInfo: [String: Any]? = nil) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: userInfo, deliverImmediately: true)
    }

    public static func observe(_ name: Notification.Name, using block: @escaping () -> Void)
        -> NSObjectProtocol
    {
        DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { _ in block() }
    }

    public static func observe(
        _ name: Notification.Name, info block: @escaping ([AnyHashable: Any]) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { note in block(note.userInfo ?? [:]) }
    }

    public static func stopObserving(_ token: NSObjectProtocol) {
        DistributedNotificationCenter.default().removeObserver(token)
    }
}
