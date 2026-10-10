import EdithExtensionSupport
import Foundation

struct NotchSettingsSnapshot: Codable, Equatable, Sendable {
    var preferences: [String: String]
    var activeIDs: Set<String>
    var browserProfile: String?

    func validate() throws {
        guard Set(preferences.keys) == Set(NotchSettingsSchema.defaults.keys),
            preferences.allSatisfy({ NotchSettingsSchema.accepts($0.key, value: $0.value) }),
            activeIDs.count <= 128,
            activeIDs.allSatisfy({ SurfaceWidget(rawValue: "extension:" + $0) != nil }),
            browserProfile.map({ $0.utf8.count <= 4096 && !$0.contains("\0") }) ?? true
        else { throw ExtensionPeerError.invalidRequest }
    }

    static let empty = Self(
        preferences: NotchSettingsSchema.defaults, activeIDs: [], browserProfile: nil)
}

struct NotchPreferenceRequest: Codable, Equatable, Sendable {
    let key: String
    let value: String

    func validate() throws {
        guard NotchSettingsSchema.accepts(key, value: value) else {
            throw ExtensionPeerError.invalidRequest
        }
    }
}

enum NotchSettingsSchema {
    static let defaults: [String: String] = [
        AppStorageKeys.Notch.shelfOpenOnHover: "1",
        AppStorageKeys.Notch.shelfOpenOnDrag: "1",
        AppStorageKeys.Notch.shelfShowOnExternal: "1",
        AppStorageKeys.Notch.shelfRemoveAfterDragOut: "1",
        AppStorageKeys.Notch.shelfRequireOption: "0",
        AppStorageKeys.Notch.shelfHaptics: "1",
        AppStorageKeys.Notch.shelfShowMusic: "1",
        AppStorageKeys.Notch.shelfKeepDuration: "forever",
        AppStorageKeys.Notch.browserEnabled: "0",
        AppStorageKeys.Notch.browserSearchEngine: BrowserSearchEngine.fallback.rawValue,
        AppStorageKeys.Notch.alertsEnabled: "1",
        AppStorageKeys.Notch.alertAudio: "1",
        AppStorageKeys.Notch.alertPower: "1",
        AppStorageKeys.Notch.alertBattery: "1",
        AppStorageKeys.Notch.alertBluetooth: "0",
    ]

    static func accepts(_ key: String, value: String) -> Bool {
        guard defaults[key] != nil else { return false }
        switch key {
        case AppStorageKeys.Notch.shelfKeepDuration:
            return ShelfKeepDuration(rawValue: value) != nil
        case AppStorageKeys.Notch.browserSearchEngine:
            return BrowserSearchEngine(rawValue: value) != nil
        default: return value == "0" || value == "1"
        }
    }

    static func isString(_ key: String) -> Bool {
        key == AppStorageKeys.Notch.shelfKeepDuration
            || key == AppStorageKeys.Notch.browserSearchEngine
    }
}
