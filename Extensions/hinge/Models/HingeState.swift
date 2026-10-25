import EdithExtensionSupport
import Foundation

public enum HingeSideFill: String, CaseIterable, Sendable {
    case blur
    case black
}

public enum HingeSettings {
    public static let openAngle = "hingeOpenAngle"
    public static let effectStrength = "hingeEffectStrength"
    public static let sideFill = "hingeSideFill"
    public static let cropsTop = "hingeCropsTop"
    public static let blursByDistance = "hingeBlursByDistance"
    public static let hotKeyCode = "hingeHotKeyCode"
    public static let hotKeyMods = "hingeHotKeyMods"
    public static let hotKeyLabel = "hingeHotKeyLabel"
    public static let sensorAvailable = "hingeSensorAvailable"
    public static let status = "hingeStatus"

    public static let strengthRange = 0.25...1.0
}

public enum HingeState {
    public static let enabledKey = "hingeEnabled"
    public static let activeKey = "hingeActive"

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
