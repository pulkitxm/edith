import Foundation

public enum HostCoreOperation: String, Codable, Sendable {
    case start, status, inspect, synchronize, restore, cancel, stop, command
}

public struct HostCoreRequest: Codable, Sendable {
    public let token: UUID
    public let operation: HostCoreOperation
    public let configuration: HostWorkerConfiguration?
    public let command: HostCoreCommandRequest?
    public let cancelling: UUID?

    public init(
        operation: HostCoreOperation, configuration: HostWorkerConfiguration? = nil,
        command: HostCoreCommandRequest? = nil, cancelling: UUID? = nil
    ) {
        token = UUID()
        self.operation = operation
        self.configuration = configuration
        self.command = command; self.cancelling = cancelling
    }
}

public struct HostCoreResponse: Codable, Sendable {
    public let token: UUID
    public let snapshot: HostCoreSnapshot?
    public let failure: String?
    public let cancelled: Bool
    public let commandResult: HostCLIJSON?
    public let commandFailure: HostAgentCommandError?

    public init(
        token: UUID, snapshot: HostCoreSnapshot? = nil, failure: String? = nil,
        cancelled: Bool = false, commandResult: HostCLIJSON? = nil,
        commandFailure: HostAgentCommandError? = nil
    ) {
        self.token = token
        self.snapshot = snapshot
        self.failure = failure
        self.cancelled = cancelled
        self.commandResult = commandResult; self.commandFailure = commandFailure
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
    public let settingsBackup: HostSettingsBackupResult?
    public let agent: HostCoreAgentSnapshot?
    public let commandTasks: [HostAgentTaskSnapshot]?

    public init(
        pid: Int32, startedAt: Date, collectedAt: Date, residentBytes: UInt64,
        cpuSeconds: Double, storage: HostStorageSnapshot?, tasks: [HostCoreTaskSnapshot],
        cloudDirectory: URL, cloudAvailable: Bool, settingsBackup: HostSettingsBackupResult? = nil,
        agent: HostCoreAgentSnapshot? = nil, commandTasks: [HostAgentTaskSnapshot]? = nil
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
        self.settingsBackup = settingsBackup
        self.agent = agent; self.commandTasks = commandTasks
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

public struct HostCoreCommandRequest: Codable, Sendable {
    public let operation: HostAgentCommandOperation
    public let payload: HostCLIJSON
    public init(operation: HostAgentCommandOperation, payload: Data = Data("{}".utf8)) throws {
        guard payload.count <= HostAgentCommandService.maximumRequestBytes else {
            throw HostAgentCommandError(.refused, "The core command request is too large.")
        }
        let value = try JSONDecoder().decode(HostCLIJSON.self, from: payload)
        guard value.object != nil else { throw HostWorkerError.rejected }
        self.operation = operation; self.payload = value
    }
    public func validate() throws {
        _ = try Self(operation: operation, payload: payload.encoded())
    }
}
