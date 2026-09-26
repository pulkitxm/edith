import Foundation

public enum ClipboardCapturePolicy {
    public enum Decision: Equatable, Sendable {
        case capture(ClipboardCaptureOptions)
        case skip(SkipReason)
    }

    public enum SkipReason: Equatable, Sendable {
        case paused, privateContent, ignoredApp
    }

    public static func isPaused(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        defaults.bool(forKey: AppStorageKeys.Clipboard.capturePaused)
    }

    public static func autoPasteEnabled(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        defaults.object(forKey: AppStorageKeys.Clipboard.autoPaste) as? Bool ?? true
    }

    public static func pastesOnPick(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        autoPasteEnabled(defaults)
            && defaults.bool(forKey: AppStorageKeys.Permissions.accessibilityGranted)
    }

    public static func decide(
        types: [String], sourceBundleID: String?,
        defaults: UserDefaults = SharedDefaults.store
    ) -> Decision {
        if isPaused(defaults) { return .skip(.paused) }
        if ClipboardPasteboardFilter.shouldSkip(types: types) { return .skip(.privateContent) }
        let ignored = ClipboardIgnore.parseUserList(
            defaults.string(forKey: AppStorageKeys.Clipboard.ignoredApps) ?? "")
        if ClipboardIgnore.isIgnored(bundleID: sourceBundleID, userList: ignored) {
            return .skip(.ignoredApp)
        }
        return .capture(
            ClipboardCaptureOptions(
                saveFiles: defaults.object(forKey: AppStorageKeys.Clipboard.saveFiles) as? Bool
                    ?? true,
                saveImages: defaults.object(forKey: AppStorageKeys.Clipboard.saveImages) as? Bool
                    ?? true,
                saveText: defaults.object(forKey: AppStorageKeys.Clipboard.saveText) as? Bool
                    ?? true))
    }
}
