import Foundation

public enum SweaterState {
    public static let enabledKey = AppStorageKeys.WindowSweaters.enabled
    public static let activeKey = AppStorageKeys.WindowSweaters.active

    public static func isEnabled(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    public static func isActive(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        guard isEnabled(defaults) else { return false }
        return defaults.object(forKey: activeKey) as? Bool ?? true
    }

    public static func setActive(_ active: Bool, _ defaults: UserDefaults = SharedDefaults.store) {
        defaults.set(active, forKey: activeKey)
    }

    public static func settings(_ defaults: UserDefaults = SharedDefaults.store) -> SweaterSettings {
        let keys = AppStorageKeys.WindowSweaters.self
        return SweaterSettings(
            active: isActive(defaults),
            pattern: SweaterPattern.from(defaults.string(forKey: keys.pattern)),
            stitch: SweaterStitch.from(defaults.string(forKey: keys.stitch)),
            basket: SweaterBaskets.basket(named: defaults.string(forKey: keys.basket)).name,
            borderWidth: SweaterLimits.clampBorderWidth(
                defaults.object(forKey: keys.borderWidth) as? Double
                    ?? SweaterLimits.defaultBorderWidth),
            gauge: SweaterLimits.clampGauge(
                defaults.object(forKey: keys.gauge) as? Double ?? SweaterLimits.defaultGauge),
            anchor: SweaterAnchor.from(defaults.string(forKey: keys.anchor)),
            order: SweaterOrder.from(defaults.string(forKey: keys.order)),
            unfocusedDim: SweaterLimits.clampDim(
                defaults.object(forKey: keys.unfocusedDim) as? Double ?? 0),
            accessibilityFocus: defaults.bool(forKey: keys.accessibilityFocus),
            excludedApps: excludedApps(defaults))
    }

    public static func excludedApps(_ defaults: UserDefaults = SharedDefaults.store) -> [String] {
        let raw = defaults.string(forKey: AppStorageKeys.WindowSweaters.excludedApps) ?? ""
        return
            raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func setExcludedApps(
        _ apps: [String], _ defaults: UserDefaults = SharedDefaults.store
    ) {
        defaults.set(apps.joined(separator: ","), forKey: AppStorageKeys.WindowSweaters.excludedApps)
    }
}
