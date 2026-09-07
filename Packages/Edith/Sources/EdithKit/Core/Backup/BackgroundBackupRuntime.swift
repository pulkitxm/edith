import Foundation

public enum BackgroundBackupSignal {
    public static let restoreRequested = Notification.Name(
        "com.pulkit.edith.backupRestoreRequested")
    public static let usageRestored = Notification.Name("com.pulkit.edith.usageBackupRestored")
    public static let limitsRestored = Notification.Name("com.pulkit.edith.limitsBackupRestored")
}

public enum BackgroundBackupClient {
    public static func restoreDataOnEnable(for dataClass: SettingsBackupDataClass) {
        IPC.post(
            BackgroundBackupSignal.restoreRequested, userInfo: ["dataClass": dataClass.rawValue])
    }
}

@MainActor
public enum BackgroundBackupRuntime {
    private static var observations: [NSObjectProtocol] = []
    private static var started = false
    private static var mailbox: BackupRequestMailbox?
    private static var worker: Task<Void, Never>?

    public static func start() {
        guard !started else { return }
        started = true
        let requests = BackupRequestMailbox()
        mailbox = requests
        observations = [
            IPC.observe(IPC.Name.settingsChanged) { requests.send(.settings) },
            IPC.observe(IPC.Name.usageRefreshFinished) { requests.send(.usage) },
            IPC.observe(IPC.Name.limitsUpdated) { requests.send(.limits) },
            IPC.observe(
                IPC.Name.clipboardChanged,
                info: { info in
                    if info["backup"] as? Bool != false { requests.send(.clipboard) }
                }),
            IPC.observe(
                BackgroundBackupSignal.restoreRequested,
                info: { info in
                    guard let name = info["dataClass"] as? String,
                        let dataClass = SettingsBackupDataClass(rawValue: name)
                    else { return }
                    requests.send(.restore(dataClass))
                }),
        ]
        worker = Task {
            for await _ in requests.stream {
                guard started, !Task.isCancelled else { break }
                apply(requests.take())
            }
        }
        SettingsBackup.shared.start()
        for dataClass in SettingsBackupDataClass.allCases where enabled(dataClass) {
            SettingsBackup.shared.restoreDataOnEnable(for: dataClass)
        }
    }

    public static func stop() async {
        guard started else { return }
        started = false
        observations.forEach(IPC.stopObserving)
        observations.removeAll()
        mailbox?.close()
        mailbox = nil
        let stoppedWorker = worker
        worker = nil
        stoppedWorker?.cancel()
        await stoppedWorker?.value
        await SettingsBackup.shared.flushForTermination()
        await SettingsBackup.shared.shutdown()
    }

    private static func apply(_ requests: BackupRequests) {
        if requests.settings { SettingsBackup.shared.settingsDidChange() }
        if requests.usage || requests.limits {
            SettingsBackup.shared.queuePersistence(
                limitsRestore: requests.limits, limitsExport: requests.limits,
                usageRestore: requests.usage, usageExport: requests.usage)
        }
        if requests.clipboard { SettingsBackup.shared.scheduleClipboardBackup() }
        for dataClass in requests.restores {
            SettingsBackup.shared.restoreDataOnEnable(for: dataClass)
        }
    }

    private static func enabled(_ dataClass: SettingsBackupDataClass) -> Bool {
        let key: String
        switch dataClass {
        case .settings: return false
        case .usage, .limits: key = AppStorageKeys.Tabs.usageEnabled
        case .music: key = AppStorageKeys.Tabs.musicEnabled
        case .clipboard: key = AppStorageKeys.Clipboard.enabled
        }
        return SharedDefaults.store.bool(forKey: key)
    }
}
