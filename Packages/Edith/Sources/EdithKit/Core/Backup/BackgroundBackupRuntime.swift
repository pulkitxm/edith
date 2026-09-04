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

    public static func start() {
        guard !started else { return }
        started = true
        observations = [
            IPC.observe(IPC.Name.settingsChanged) {
                Task { @MainActor in
                    guard started else { return }
                    SettingsBackup.shared.settingsDidChange()
                }
            },
            IPC.observe(IPC.Name.usageRefreshFinished) {
                Task { @MainActor in
                    guard started else { return }
                    SettingsBackup.shared.queuePersistence(
                        limitsRestore: false, limitsExport: false, usageRestore: true,
                        usageExport: true)
                }
            },
            IPC.observe(IPC.Name.limitsUpdated) {
                Task { @MainActor in
                    guard started else { return }
                    SettingsBackup.shared.queuePersistence(
                        limitsRestore: true, limitsExport: true, usageRestore: false,
                        usageExport: false)
                }
            },
            IPC.observe(
                IPC.Name.clipboardChanged,
                info: { info in
                    guard info["backup"] as? Bool != false else { return }
                    Task { @MainActor in
                        guard started else { return }
                        SettingsBackup.shared.scheduleClipboardBackup()
                    }
                }),
            IPC.observe(
                BackgroundBackupSignal.restoreRequested,
                info: { info in
                    guard let name = info["dataClass"] as? String,
                        let dataClass = SettingsBackupDataClass(rawValue: name)
                    else { return }
                    Task { @MainActor in
                        guard started else { return }
                        SettingsBackup.shared.restoreDataOnEnable(for: dataClass)
                    }
                }),
        ]
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
        await SettingsBackup.shared.flushForTermination()
        await SettingsBackup.shared.shutdown()
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
