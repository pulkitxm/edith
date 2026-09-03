import EdithCore
import Foundation

public enum SuiteEnablement {
    public static func restoreKey(for suite: SuiteID) -> String {
        "suite\(suite.rawValue.capitalized)Restore"
    }

    public static func isEnabled(
        _ suite: SuiteID, defaults: UserDefaults = SharedDefaults.store
    ) -> Bool {
        SuiteRegistry.isEnabled(suite, in: defaults)
    }

    public static func selectedAbilities(
        in suite: SuiteID, defaults: UserDefaults = SharedDefaults.store
    ) -> [ExtensionRegistryEntry] {
        SuiteRegistry.abilities(in: suite).filter { $0.isSelected(in: defaults) }
    }

    public static func enabledAbilities(
        in suite: SuiteID, defaults: UserDefaults = SharedDefaults.store
    ) -> [ExtensionRegistryEntry] {
        SuiteRegistry.abilities(in: suite).filter { $0.isEnabled(in: defaults) }
    }

    @discardableResult
    public static func setEnabled(
        _ enabled: Bool, suite: SuiteID, defaults: UserDefaults = SharedDefaults.store
    ) -> [ExtensionRegistryEntry] {
        let descriptor = SuiteRegistry.suite(suite)
        let abilities = SuiteRegistry.abilities(in: suite)
        if enabled {
            defaults.set(true, forKey: descriptor.defaultsKey)
            let remembered = Set(
                defaults.stringArray(forKey: restoreKey(for: suite)) ?? abilities.map(\.id))
            for ability in abilities where remembered.contains(ability.id) {
                defaults.set(true, forKey: ability.defaultsKey)
            }
            defaults.removeObject(forKey: restoreKey(for: suite))
        } else {
            let remembered = abilities.filter { $0.isSelected(in: defaults) }.map(\.id)
            defaults.set(remembered, forKey: restoreKey(for: suite))
            for ability in abilities {
                defaults.set(false, forKey: ability.defaultsKey)
            }
            defaults.set(false, forKey: descriptor.defaultsKey)
        }
        return enabledAbilities(in: suite, defaults: defaults)
    }
}
