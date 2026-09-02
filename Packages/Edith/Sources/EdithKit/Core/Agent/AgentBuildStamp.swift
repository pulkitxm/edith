import Foundation

public enum AgentBuildStamp {
    public static let key = "installedBuild"

    public static func currentBuild(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
    }

    public static func hasChanged(
        defaults: UserDefaults = SharedDefaults.store, bundle: Bundle = .main
    ) -> Bool {
        stampIsStale(recorded: defaults.string(forKey: key), current: currentBuild(bundle: bundle))
    }

    public static func stampIsStale(recorded: String?, current: String) -> Bool {
        guard let recorded else { return true }
        return recorded != current
    }

    public static func record(
        defaults: UserDefaults = SharedDefaults.store, bundle: Bundle = .main
    ) {
        defaults.set(currentBuild(bundle: bundle), forKey: key)
    }
}
