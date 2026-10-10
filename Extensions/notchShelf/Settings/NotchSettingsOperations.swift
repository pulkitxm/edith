import AppKit
import CoreBluetooth
import EdithExtensionSupport
import Foundation

extension NotchShelfController {
    func settingsSnapshot() -> NotchSettingsSnapshot {
        var result = NotchSettingsSchema.defaults
        for (key, fallback) in NotchSettingsSchema.defaults {
            if NotchSettingsSchema.isString(key) {
                let value = context.defaults.string(forKey: key) ?? fallback
                result[key] = NotchSettingsSchema.accepts(key, value: value) ? value : fallback
            } else {
                result[key] =
                    (context.defaults.object(forKey: key) as? Bool ?? (fallback == "1")) ? "1" : "0"
            }
        }
        return .init(
            preferences: result, activeIDs: activeIDs,
            browserProfile: browser?.profile?.name ?? browserEngine?.profileName,
            bluetoothPrivacyRequired: CBManager.authorization == .denied
                || CBManager.authorization == .restricted)
    }

    func executeSettings(_ command: String, payload: Data) throws -> Data {
        guard isRunning else { throw ExtensionPeerError.unavailable }
        switch command {
        case "notch.settings.read": break
        case "notch.settings.write":
            guard payload.count <= 4096 else { throw ExtensionPeerError.invalidRequest }
            let request = try JSONDecoder().decode(NotchPreferenceRequest.self, from: payload)
            try request.validate()
            if NotchSettingsSchema.isString(request.key) {
                context.defaults.set(request.value, forKey: request.key)
            } else {
                context.defaults.set(request.value == "1", forKey: request.key)
            }
            synchronize()
            if startsPanelServices { rebuildPanels() }
        case "notch.bluetooth.settings":
            guard
                let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
            else {
                throw ExtensionPeerError.unavailable
            }
            guard NSWorkspace.shared.open(url) else { throw ExtensionPeerError.unavailable }
        case "notch.customize": openCustomization()
        case "notch.browser.detach":
            browser?.detach()
            browserEngine?.detach()
        default: throw ExtensionPeerError.invalidRequest
        }
        return try JSONEncoder().encode(settingsSnapshot())
    }
}
