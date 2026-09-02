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
        public static let updateReadyToInstall = Notification.Name(
            "com.pulkit.edith.updateReadyToInstall")
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
        public static let requestColorPick = Notification.Name(
            "com.pulkit.edith.requestColorPick")
        public static let requestEmojiPanel = Notification.Name(
            "com.pulkit.edith.requestEmojiPanel")
        public static let requestEmojiInsert = Notification.Name(
            "com.pulkit.edith.requestEmojiInsert")
        public static let emojiInsertResult = Notification.Name(
            "com.pulkit.edith.emojiInsertResult")
        public static let shelfChanged = Notification.Name("com.pulkit.edith.shelfChanged")
        public static let shelfOperation = Notification.Name("com.pulkit.edith.shelfOperation")
        public static let shelfOperationResult = Notification.Name(
            "com.pulkit.edith.shelfOperationResult")
        public static let machinesChanged = Notification.Name("com.pulkit.edith.machinesChanged")
        public static let requestMachineTerminalBroadcast = Notification.Name(
            "com.pulkit.edith.requestMachineTerminalBroadcast")
        public static let machineTerminalBroadcastResult = Notification.Name(
            "com.pulkit.edith.machineTerminalBroadcastResult")
        public static let downloadQueueChanged = Notification.Name(
            "com.pulkit.edith.downloadQueueChanged")
        public static let requestQuitApps = Notification.Name(
            "com.pulkit.edith.requestQuitApps")
        public static let quitAppsResult = Notification.Name(
            "com.pulkit.edith.quitAppsResult")
        public static let requestFinderUndo = Notification.Name(
            "com.pulkit.edith.requestFinderUndo")
        public static let requestDownloadCancel = Notification.Name(
            "com.pulkit.edith.requestDownloadCancel")
        public static let finderUndoResult = Notification.Name(
            "com.pulkit.edith.finderUndoResult")
        public static let presenterAutoActiveChanged = Notification.Name(
            "com.pulkit.edith.presenterAutoActiveChanged")
        public static let musicCommand = Notification.Name("com.pulkit.edith.musicCommand")
        public static let nowPlayingCommand = Notification.Name(
            "com.pulkit.edith.nowPlayingCommand")
        public static let nowPlayingState = Notification.Name("com.pulkit.edith.nowPlayingState")
        public static let requestNowPlayingState = Notification.Name(
            "com.pulkit.edith.requestNowPlayingState")
        public static let musicState = Notification.Name("com.pulkit.edith.musicState")
        public static let requestMusicState = Notification.Name(
            "com.pulkit.edith.requestMusicState")
        public static let musicLevel = Notification.Name("com.pulkit.edith.musicLevel")
        public static let requestMusicLevels = Notification.Name(
            "com.pulkit.edith.requestMusicLevels")
        public static let requestKeyboardClean = Notification.Name(
            "com.pulkit.edith.requestKeyboardClean")
        public static let keyboardCleanResult = Notification.Name(
            "com.pulkit.edith.keyboardCleanResult")
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
        public static let requestLidAwakeAction = Notification.Name(
            "com.pulkit.edith.requestLidAwakeAction")
        public static let lidAwakeActionResult = Notification.Name(
            "com.pulkit.edith.lidAwakeActionResult")
        public static let lidAwakeChanged = Notification.Name("com.pulkit.edith.lidAwakeChanged")
        public static let requestUpdateCheck = Notification.Name(
            "com.pulkit.edith.requestUpdateCheck")
        public static let updateCheckFinished = Notification.Name(
            "com.pulkit.edith.updateCheckFinished")
        public static let requestCalendarEvents = Notification.Name(
            "com.pulkit.edith.requestCalendarEvents")
        public static let calendarEvents = Notification.Name("com.pulkit.edith.calendarEvents")
        public static let requestReveal = Notification.Name("com.pulkit.edith.requestReveal")
        public static let revealResult = Notification.Name("com.pulkit.edith.revealResult")
        public static let requestWindowSnapshot = Notification.Name(
            "com.pulkit.edith.requestWindowSnapshot")
        public static let windowSnapshotResult = Notification.Name(
            "com.pulkit.edith.windowSnapshotResult")
        public static let requestAppDiagnostics = Notification.Name(
            "com.pulkit.edith.requestAppDiagnostics")
        public static let appDiagnostics = Notification.Name(
            "com.pulkit.edith.appDiagnostics")
        public static let requestQuinjetSessionOperation = Notification.Name(
            "com.pulkit.edith.requestQuinjetSessionOperation")
        public static let quinjetSessionOperationResult = Notification.Name(
            "com.pulkit.edith.quinjetSessionOperationResult")
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
