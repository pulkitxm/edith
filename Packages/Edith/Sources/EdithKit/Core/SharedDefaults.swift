import Foundation

public enum SharedDefaults {
    public static let suiteName = "com.pulkit.edith.shared"
    public static let registeredDefaults: [String: Any] = [
        "icloudBackup": true,
        CompletionScripts.autoRefreshKey: true,
        MusicFade.enabledKey: true,
        MusicFade.secondsKey: MusicFade.defaultSeconds,
    ]
    public static let store: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName) ?? .standard
        store.register(defaults: registeredDefaults)
        return store
    }()

    public static func migrate(
        from source: UserDefaults = .standard,
        to destination: UserDefaults = SharedDefaults.store,
        flagKey: String = "migratedToSharedSuite"
    ) {
        guard !destination.bool(forKey: flagKey) else { return }
        for (key, value) in source.dictionaryRepresentation() {
            guard !key.hasPrefix("NS"), !key.hasPrefix("Apple") else { continue }
            if destination.object(forKey: key) == nil {
                destination.set(value, forKey: key)
            }
        }
        destination.set(true, forKey: flagKey)
    }
}
