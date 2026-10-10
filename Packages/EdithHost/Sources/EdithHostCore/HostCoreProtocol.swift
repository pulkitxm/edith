import Foundation

public enum HostCoreOperation: String, Codable, Sendable {
    case start, status, inspect, synchronize, cancel, stop
}

public struct HostCoreRequest: Codable, Sendable {
    public let token: UUID
    public let operation: HostCoreOperation
    public let configuration: HostWorkerConfiguration?

    public init(operation: HostCoreOperation, configuration: HostWorkerConfiguration? = nil) {
        token = UUID()
        self.operation = operation
        self.configuration = configuration
    }
}

public struct HostCoreResponse: Codable, Sendable {
    public let token: UUID
    public let snapshot: HostCoreSnapshot?
    public let failure: String?

    public init(token: UUID, snapshot: HostCoreSnapshot? = nil, failure: String? = nil) {
        self.token = token
        self.snapshot = snapshot
        self.failure = failure
    }
}

public struct HostCoreSnapshot: Codable, Sendable {
    public let pid: Int32
    public let startedAt: Date
    public let collectedAt: Date
    public let residentBytes: UInt64
    public let cpuSeconds: Double
    public let storage: HostStorageSnapshot?
    public let tasks: [HostCoreTaskSnapshot]
    public let cloudDirectory: URL
    public let cloudAvailable: Bool

    public init(
        pid: Int32, startedAt: Date, collectedAt: Date, residentBytes: UInt64,
        cpuSeconds: Double, storage: HostStorageSnapshot?, tasks: [HostCoreTaskSnapshot],
        cloudDirectory: URL, cloudAvailable: Bool
    ) {
        self.pid = pid
        self.startedAt = startedAt
        self.collectedAt = collectedAt
        self.residentBytes = residentBytes
        self.cpuSeconds = cpuSeconds
        self.storage = storage
        self.tasks = tasks
        self.cloudDirectory = cloudDirectory
        self.cloudAvailable = cloudAvailable
    }
}

public struct HostCoreTaskSnapshot: Codable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable { case running, completed, cancelled, failed }
    public let id: UUID
    public let title: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let phase: Phase
    public let message: String?
}

public struct HostStorageSnapshot: Codable, Sendable {
    public let collectedAt: Date
    public let footprints: [HostStorageFootprint]
    public let restoreEntries: [HostStorageRestoreEntry]
    public let issues: [String]
}

public struct HostStorageFootprint: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let bytes: Int64
    public let exists: Bool
}

public struct HostStorageRestoreEntry: Codable, Identifiable, Sendable {
    public let name: String
    public let bytes: Int64
    public var id: String { name }
}
