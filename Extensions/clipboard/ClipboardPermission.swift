import ApplicationServices
import EdithExtensionSupport

@MainActor
enum ClipboardPermission {
    static func refresh() {
        let trusted = AXIsProcessTrusted()
        if SharedDefaults.store.bool(forKey: AppStorageKeys.Permissions.accessibilityGranted)
            != trusted
        {
            SharedDefaults.store.set(
                trusted, forKey: AppStorageKeys.Permissions.accessibilityGranted)
            IPC.post(IPC.Name.settingsChanged)
        }
    }

    static func request() {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }
}
