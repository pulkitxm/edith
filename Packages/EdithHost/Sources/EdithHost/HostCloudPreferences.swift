import EdithExtensionSupport
import EdithHostCore
import Foundation

@MainActor struct HostCloudPreferences {
    enum Option: CaseIterable {
        case icloud, settings, usage, limits, music, clipboard
        var key: String {
            switch self {
            case .icloud: AppStorageKeys.Backup.icloud
            case .settings: AppStorageKeys.Backup.settings
            case .usage: AppStorageKeys.Backup.usage
            case .limits: AppStorageKeys.Backup.limits
            case .music: AppStorageKeys.Music.backup
            case .clipboard: AppStorageKeys.Clipboard.backup
            }
        }
        var defaultValue: Bool { self != .music && self != .clipboard }
    }
    let application: UserDefaults
    let music: UserDefaults
    let clipboard: UserDefaults

    init(identity: HostIdentity, application: UserDefaults) throws {
        self.application = application
        guard let music = UserDefaults(suiteName: identity.extensionDefaultsSuite("music")),
            let clipboard = UserDefaults(suiteName: identity.extensionDefaultsSuite("clipboard"))
        else { throw HostWorkerError.rejected }
        self.music = music; self.clipboard = clipboard
    }

    private func store(_ option: Option) -> UserDefaults {
        switch option {
        case .music: music
        case .clipboard: clipboard
        default: application
        }
    }

    func enabled(_ option: Option) -> Bool {
        store(option).object(forKey: option.key) as? Bool ?? option.defaultValue
    }

    var readyForSettingsBackup: Bool {
        enabled(.icloud) && enabled(.settings)
            && application.bool(forKey: HostSettingsCatalog.onboardingCompletedKey)
    }

    func set(_ option: Option, enabled: Bool) {
        store(option).set(enabled, forKey: option.key)
        store(option).synchronize()
        IPC.post(IPC.Name.settingsChanged)
    }

    func lastBackup(_ option: Option) -> Date? {
        let key: String
        switch option {
        case .music: key = AppStorageKeys.Music.lastBackupAt
        case .clipboard: key = AppStorageKeys.Clipboard.lastBackupAt
        default: key = AppStorageKeys.Backup.lastBackupAt
        }
        let value = store(option).double(forKey: key)
        guard value.isFinite, value > 0, value <= 1e12 else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}
