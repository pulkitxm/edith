import Foundation

public enum ExtensionDefaults {
    public static let systemAppearanceKey = "AppleInterfaceStyle"

    public static func applicationStore(identifier: String) -> UserDefaults? {
        if identifier == "com.pulkit.edith" {
            return UserDefaults(suiteName: identifier + ".shared")
        }
        if Bundle.main.bundleIdentifier == identifier { return .standard }
        return UserDefaults(suiteName: identifier)
    }

    public static func resolvedSuite(environment: [String: String], applicationIdentifier: String?)
        -> String?
    {
        if let suite = environment["EDITH_SHARED_DEFAULTS_SUITE"] { return suite }
        return applicationIdentifier == "com.pulkit.edith" ? "com.pulkit.edith.shared" : nil
    }

    public static func store(environment: [String: String], applicationIdentifier: String?)
        -> UserDefaults
    {
        guard
            let suite = resolvedSuite(
                environment: environment, applicationIdentifier: applicationIdentifier),
            let defaults = UserDefaults(suiteName: suite)
        else { return .standard }
        return defaults
    }
}
