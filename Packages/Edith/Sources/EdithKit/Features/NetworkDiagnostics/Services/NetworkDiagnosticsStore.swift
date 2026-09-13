import Foundation

public enum NetworkDiagnosticsPreferences {
    public static func configuration(
        defaults: UserDefaults = SharedDefaults.store
    ) -> NetworkDiagnosticsConfiguration {
        guard let data = defaults.data(forKey: AppStorageKeys.NetworkDiagnostics.configuration),
            let value = try? JSONDecoder().decode(NetworkDiagnosticsConfiguration.self, from: data)
        else { return NetworkDiagnosticsConfiguration() }
        return value.normalized
    }

    public static func save(
        _ configuration: NetworkDiagnosticsConfiguration,
        defaults: UserDefaults = SharedDefaults.store
    ) {
        defaults.set(
            try? JSONEncoder().encode(configuration.normalized),
            forKey: AppStorageKeys.NetworkDiagnostics.configuration)
    }

    public static func baseline(
        defaults: UserDefaults = SharedDefaults.store
    ) -> NetworkDiagnosticSnapshot? {
        guard let data = defaults.data(forKey: AppStorageKeys.NetworkDiagnostics.baseline)
        else { return nil }
        return try? JSONDecoder().decode(NetworkDiagnosticSnapshot.self, from: data)
    }

    public static func saveBaseline(
        _ snapshot: NetworkDiagnosticSnapshot?, defaults: UserDefaults = SharedDefaults.store
    ) {
        defaults.set(
            snapshot.flatMap { try? JSONEncoder().encode($0) },
            forKey: AppStorageKeys.NetworkDiagnostics.baseline)
    }
}
