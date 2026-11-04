import EdithExtensionSupport
import Foundation

public struct UsageMachineRefreshStatus: Codable, Equatable, Sendable {
    public var attemptedAt: Date
    public var succeededAt: Date?
    public var failure: String?

    public init(attemptedAt: Date, succeededAt: Date? = nil, failure: String? = nil) {
        self.attemptedAt = attemptedAt
        self.succeededAt = succeededAt
        self.failure = failure
    }
}

public enum UsageMachineRefreshLedger {
    static let fileName = "machine-refresh.json"
    static let maximumBytes = 1_048_576
    public static let machinesUnavailable =
        "The Machines extension is not running, so this machine could not be reached"
    private static let lock = NSLock()

    public static func load(directory: URL = Repo.dataDir) -> [UUID: UsageMachineRefreshStatus] {
        lock.withLock { read(directory) }
    }

    public static func recordSuccess(
        _ machineID: UUID, at date: Date = Date(), directory: URL = Repo.dataDir
    ) {
        update(directory) { entries in
            entries[machineID] = UsageMachineRefreshStatus(attemptedAt: date, succeededAt: date)
        }
    }

    public static func recordFailure(
        _ machineID: UUID, reason: String, at date: Date = Date(), directory: URL = Repo.dataDir
    ) {
        update(directory) { entries in
            entries[machineID] = UsageMachineRefreshStatus(
                attemptedAt: date, succeededAt: entries[machineID]?.succeededAt,
                failure: String(reason.prefix(512)))
        }
    }

    public static func forget(_ machineID: UUID, directory: URL = Repo.dataDir) {
        update(directory) { $0.removeValue(forKey: machineID) }
    }

    static func needsRecovery(
        _ machineIDs: some Sequence<UUID>, directory: URL = Repo.dataDir
    ) -> Bool {
        let entries = load(directory: directory)
        return machineIDs.contains { entries[$0]?.failure != nil }
    }

    private static func update(
        _ directory: URL, _ change: (inout [UUID: UsageMachineRefreshStatus]) -> Void
    ) {
        lock.withLock {
            var entries = read(directory)
            change(&entries)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .sortedKeys
            let keyed = Dictionary(
                uniqueKeysWithValues: entries.prefix(256).map {
                    ($0.key.uuidString.lowercased(), $0.value)
                })
            guard let data = try? encoder.encode(keyed), data.count <= maximumBytes else { return }
            try? UsageDataFiles.write(data, to: directory.appendingPathComponent(fileName))
        }
    }

    private static func read(_ directory: URL) -> [UUID: UsageMachineRefreshStatus] {
        guard
            let data = try? UsageDataFiles.readRegularFile(
                at: directory.appendingPathComponent(fileName), maximumBytes: maximumBytes)
        else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let keyed = try? decoder.decode([String: UsageMachineRefreshStatus].self, from: data)
        else { return [:] }
        return Dictionary(
            keyed.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } }
        ) { first, _ in first }
    }
}
