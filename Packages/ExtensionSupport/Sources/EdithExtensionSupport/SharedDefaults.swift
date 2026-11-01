import Foundation

public enum SharedDefaults {
    public static let systemAppearanceKey = ExtensionDefaults.systemAppearanceKey

    public static func applicationStore(identifier: String) -> UserDefaults? {
        ExtensionDefaults.applicationStore(identifier: identifier)
    }

    public static func resolvedSuite(environment: [String: String], applicationIdentifier: String?)
        -> String?
    {
        ExtensionDefaults.resolvedSuite(
            environment: environment, applicationIdentifier: applicationIdentifier)
    }

    public static let store: UserDefaults = ExtensionDefaults.store(
        environment: ExtensionEnvironment.values,
        applicationIdentifier: Bundle.main.bundleIdentifier)
}
