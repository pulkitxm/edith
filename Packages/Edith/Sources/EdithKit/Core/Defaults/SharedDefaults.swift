import Foundation

public enum SharedDefaults {
    public static let suiteName = "com.pulkit.edith.shared"
    private static var activeSuiteName: String {
        ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"] ?? suiteName
    }
    public static let registeredDefaults: [String: Any] = [
        AppStorageKeys.Backup.icloud: true,
        CompletionScripts.autoRefreshKey: true,
        MusicFade.enabledKey: true,
        MusicFade.secondsKey: MusicFade.defaultSeconds,
        AppStorageKeys.MediaToolkit.imageFormat: MediaImageFormat.jpeg.rawValue,
        AppStorageKeys.MediaToolkit.imageMaxDimension: 1600,
        AppStorageKeys.MediaToolkit.imageQuality: 0.82,
        AppStorageKeys.MediaToolkit.videoKeepAudio: true,
        AppStorageKeys.MediaToolkit.videoTargetMegabytes: 20,
    ]
    public static let store: UserDefaults = {
        let store = UserDefaults(suiteName: activeSuiteName) ?? .standard
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
