import EdithExtensionSupport
import Foundation

struct ClipboardPreferences: Codable, Equatable, Sendable {
    static let hotKeyLabelKey = "clipboardHotKeyLabel"

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
        value.hotKeyLabel = defaults.string(forKey: Self.hotKeyLabelKey) ?? "⌃⇧C"
        return value.clamped()
    }

    func clamped() -> Self {
        var value = self
        value.maxItems = min(999, max(1, maxItems))
        value.maxItemBytes = min(ClipboardArchive.maximumBlobBytes, max(1_000_000, maxItemBytes))
        value.maxAgeDays = [0, 7, 30, 90].min { abs($0 - maxAgeDays) < abs($1 - maxAgeDays) } ?? 0
        value.checkInterval =
            checkInterval.isFinite
            ? min(5, max(0.2, checkInterval)) : ClipboardIndex.defaultCheckInterval
        if !["cursor", "statusItem", "window", "center", "lastPosition"].contains(popupAt) {
            value.popupAt = "cursor"
        }
        if !["top", "bottom"].contains(pinTo) { value.pinTo = "top" }
        while value.ignoredApps.utf8.count > 8192 { value.ignoredApps.removeLast() }
        value.hotKeyCode = (0...127).contains(hotKeyCode) ? hotKeyCode : 8
        value.hotKeyMods = hotKeyMods & 6912
        if value.hotKeyMods == 0 { value.hotKeyMods = 4608 }
        if hotKeyLabel.utf8.count > 80 { value.hotKeyLabel = "⌃⇧C" }
        return value
    }

    static func patched(_ defaults: UserDefaults, with patch: Data) throws -> Self {
        guard
            let current = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(read(defaults))) as? [String: Any],
            let changes = try JSONSerialization.jsonObject(with: patch) as? [String: Any],
            Set(changes.keys).isSubset(of: Set(current.keys))
        else { throw ExtensionPeerError.invalidRequest }
        let merged = current.merging(changes) { _, new in new }
        return try JSONDecoder().decode(
            Self.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    func changes(from base: Self) throws -> Data {
        let encoder = JSONEncoder()
        guard
            let old = try JSONSerialization.jsonObject(with: encoder.encode(base))
                as? [String: Any],
            let new = try JSONSerialization.jsonObject(with: encoder.encode(self))
                as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        let changed = new.filter { key, value in
            guard let previous = old[key] else { return true }
            return !(previous as AnyObject).isEqual(value)
        }
        return try JSONSerialization.data(withJSONObject: changed)
    }

    func save(_ defaults: UserDefaults) throws {
        let value = clamped()
        defaults.set(value.maxItems, forKey: AppStorageKeys.Clipboard.maxItems)
        defaults.set(value.maxItemBytes, forKey: AppStorageKeys.Clipboard.maxItemBytes)
        defaults.set(value.maxAgeDays, forKey: AppStorageKeys.Clipboard.maxAgeDays)
        defaults.set(value.ignoredApps, forKey: AppStorageKeys.Clipboard.ignoredApps)
        defaults.set(value.autoPaste, forKey: AppStorageKeys.Clipboard.autoPaste)
        defaults.set(value.capturePaused, forKey: AppStorageKeys.Clipboard.capturePaused)
        defaults.set(value.pastePlainText, forKey: AppStorageKeys.Clipboard.pastePlainText)
        defaults.set(value.checkInterval, forKey: AppStorageKeys.Clipboard.checkInterval)
        defaults.set(value.popupAt, forKey: AppStorageKeys.Clipboard.popupAt)
        defaults.set(value.pinTo, forKey: AppStorageKeys.Clipboard.pinTo)
        defaults.set(value.showFooter, forKey: AppStorageKeys.Clipboard.showFooter)
        defaults.set(value.saveFiles, forKey: AppStorageKeys.Clipboard.saveFiles)
        defaults.set(value.saveImages, forKey: AppStorageKeys.Clipboard.saveImages)
        defaults.set(value.saveText, forKey: AppStorageKeys.Clipboard.saveText)
        defaults.set(value.hotKeyCode, forKey: "clipboardHotKeyCode")
        defaults.set(value.hotKeyMods, forKey: "clipboardHotKeyMods")
        defaults.set(value.hotKeyLabel, forKey: Self.hotKeyLabelKey)
        IPC.post(IPC.Name.settingsChanged)
    }
}
