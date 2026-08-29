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

public actor NetworkDiagnosticsTimelineStore {
    public static let shared = NetworkDiagnosticsTimelineStore()

    private let file: URL
    private let fileManager: FileManager

    public init(
        file: URL = AppData.supportDir.appendingPathComponent(
            "network-diagnostics/timeline.json"),
        fileManager: FileManager = .default
    ) {
        self.file = file
        self.fileManager = fileManager
    }

    public func load(limit: Int = 100) -> [NetworkDiagnosticSnapshot] {
        guard let data = try? Data(contentsOf: file),
            let snapshots = try? JSONDecoder().decode([NetworkDiagnosticSnapshot].self, from: data)
        else { return [] }
        return Array(snapshots.prefix(max(1, limit)))
    }

    @discardableResult
    public func append(
        _ snapshot: NetworkDiagnosticSnapshot, limit: Int
    ) throws -> [NetworkDiagnosticSnapshot] {
        var snapshots = load(limit: limit)
        snapshots.removeAll { $0.id == snapshot.id }
        snapshots.insert(snapshot, at: 0)
        snapshots = Array(snapshots.prefix(max(1, limit)))
        try fileManager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshots)
        try data.write(to: file, options: .atomic)
        return snapshots
    }

    public func clear() throws {
        if fileManager.fileExists(atPath: file.path) { try fileManager.removeItem(at: file) }
    }
}
