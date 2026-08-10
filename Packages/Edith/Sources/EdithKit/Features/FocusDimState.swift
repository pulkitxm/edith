import Foundation

public enum FocusDimState {
    public static let enabledKey = "focusDimEnabled"
    public static let activeKey = "focusDimActive"

    public static func isEnabled(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    public static func isActive(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        isEnabled(defaults) && defaults.bool(forKey: activeKey)
    }

    public static func setActive(_ active: Bool, _ defaults: UserDefaults = SharedDefaults.store) {
        defaults.set(active, forKey: activeKey)
    }
}
