import EdithExtensionSupport
import Foundation

struct ClipboardPreferences: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var maxItems: Int = ClipboardIndex.defaultMaxItems
    var maxItemBytes: Int = ClipboardIndex.defaultMaxItemBytes
    var maxAgeDays: Int = 0
    var ignoredApps: String = ""
    var autoPaste: Bool = true
    var capturePaused: Bool = false
    var pastePlainText: Bool = false
    var checkInterval: Double = ClipboardIndex.defaultCheckInterval
    var popupAt: String = "cursor"
    var pinTo: String = "top"
    var showFooter: Bool = true
    var saveFiles: Bool = true
    var saveImages: Bool = true
    var saveText: Bool = true
    var accessibilityGranted = false
    var hotKeyCode = 8
    var hotKeyMods = 4608
    var hotKeyLabel = "⌃⇧C"

    static func read(_ defaults: UserDefaults) -> Self {
        var value = Self()
        value.enabled = defaults.object(forKey: AppStorageKeys.Clipboard.enabled) as? Bool ?? false
        value.maxItems =
            defaults.object(forKey: AppStorageKeys.Clipboard.maxItems) as? Int
            ?? ClipboardIndex.defaultMaxItems
        value.maxItemBytes =
            defaults.object(forKey: AppStorageKeys.Clipboard.maxItemBytes) as? Int
            ?? ClipboardIndex.defaultMaxItemBytes
        value.maxAgeDays = defaults.object(forKey: AppStorageKeys.Clipboard.maxAgeDays) as? Int ?? 0
        value.ignoredApps =
            defaults.object(forKey: AppStorageKeys.Clipboard.ignoredApps) as? String ?? ""
        value.autoPaste =
            defaults.object(forKey: AppStorageKeys.Clipboard.autoPaste) as? Bool ?? true
        value.capturePaused =
            defaults.object(forKey: AppStorageKeys.Clipboard.capturePaused) as? Bool ?? false
        value.pastePlainText =
            defaults.object(forKey: AppStorageKeys.Clipboard.pastePlainText) as? Bool ?? false
        value.checkInterval =
            defaults.object(forKey: AppStorageKeys.Clipboard.checkInterval) as? Double
            ?? ClipboardIndex.defaultCheckInterval
        value.popupAt =
            defaults.object(forKey: AppStorageKeys.Clipboard.popupAt) as? String ?? "cursor"
        value.pinTo = defaults.object(forKey: AppStorageKeys.Clipboard.pinTo) as? String ?? "top"
        value.showFooter =
            defaults.object(forKey: AppStorageKeys.Clipboard.showFooter) as? Bool ?? true
        value.saveFiles =
            defaults.object(forKey: AppStorageKeys.Clipboard.saveFiles) as? Bool ?? true
        value.saveImages =
            defaults.object(forKey: AppStorageKeys.Clipboard.saveImages) as? Bool ?? true
        value.saveText = defaults.object(forKey: AppStorageKeys.Clipboard.saveText) as? Bool ?? true
        value.accessibilityGranted = defaults.bool(
            forKey: AppStorageKeys.Permissions.accessibilityGranted)
        value.hotKeyCode = defaults.object(forKey: "clipboardHotKeyCode") as? Int ?? 8
        value.hotKeyMods = defaults.object(forKey: "clipboardHotKeyMods") as? Int ?? 4608
        value.hotKeyLabel = defaults.string(forKey: "clipboardHotKeyLabel") ?? "⌃⇧C"
        return value
    }

    func save(_ defaults: UserDefaults) throws {
        guard (1...999).contains(maxItems),
            (1_000_000...ClipboardArchive.maximumBlobBytes).contains(maxItemBytes),
            [0, 7, 30, 90].contains(maxAgeDays), checkInterval.isFinite,
            (0.2...5).contains(checkInterval),
            ["cursor", "statusItem", "window", "center", "lastPosition"].contains(popupAt),
            ["top", "bottom"].contains(pinTo), ignoredApps.utf8.count <= 8192,
            (0...127).contains(hotKeyCode), hotKeyMods > 0, hotKeyMods & ~6912 == 0,
            hotKeyLabel.utf8.count <= 80
        else { throw ExtensionPeerError.invalidRequest }
        defaults.set(enabled, forKey: AppStorageKeys.Clipboard.enabled)
        defaults.set(maxItems, forKey: AppStorageKeys.Clipboard.maxItems)
        defaults.set(maxItemBytes, forKey: AppStorageKeys.Clipboard.maxItemBytes)
        defaults.set(maxAgeDays, forKey: AppStorageKeys.Clipboard.maxAgeDays)
        defaults.set(ignoredApps, forKey: AppStorageKeys.Clipboard.ignoredApps)
        defaults.set(autoPaste, forKey: AppStorageKeys.Clipboard.autoPaste)
        defaults.set(capturePaused, forKey: AppStorageKeys.Clipboard.capturePaused)
        defaults.set(pastePlainText, forKey: AppStorageKeys.Clipboard.pastePlainText)
        defaults.set(checkInterval, forKey: AppStorageKeys.Clipboard.checkInterval)
        defaults.set(popupAt, forKey: AppStorageKeys.Clipboard.popupAt)
        defaults.set(pinTo, forKey: AppStorageKeys.Clipboard.pinTo)
        defaults.set(showFooter, forKey: AppStorageKeys.Clipboard.showFooter)
        defaults.set(saveFiles, forKey: AppStorageKeys.Clipboard.saveFiles)
        defaults.set(saveImages, forKey: AppStorageKeys.Clipboard.saveImages)
        defaults.set(saveText, forKey: AppStorageKeys.Clipboard.saveText)
        defaults.set(hotKeyCode, forKey: "clipboardHotKeyCode")
        defaults.set(hotKeyMods, forKey: "clipboardHotKeyMods")
        defaults.set(hotKeyLabel, forKey: "clipboardHotKeyLabel")
        IPC.post(IPC.Name.settingsChanged)
    }
}
