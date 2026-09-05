import Foundation

public struct StorageRestoreEntry: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let bytes: Int64
    public var id: String { name }

    public init(name: String, bytes: Int64) {
        self.name = name
        self.bytes = bytes
    }
}

public struct StorageInspectionSnapshot: Codable, Sendable {
    public let collectedAt: Date
    public let footprints: [BackupFootprint]
    public let restoreEntries: [StorageRestoreEntry]
    public let issues: [String]

    public init(
        collectedAt: Date = Date(), footprints: [BackupFootprint],
        restoreEntries: [StorageRestoreEntry], issues: [String]
    ) {
        self.collectedAt = collectedAt
        self.footprints = footprints
        self.restoreEntries = restoreEntries
        self.issues = issues
    }
}

public struct StorageInspectionClient: Sendable {
    public static let operation = "storage.inspect"
    private let tasks: AgentTaskClient

    public init(client: AgentClient = .shared) { tasks = AgentTaskClient(client: client) }

    public func inspect(force: Bool = false) async throws -> StorageInspectionSnapshot {
        let data = try await tasks.run(
            AgentTaskSubmission(
                operation: Self.operation, title: "Inspecting storage and backup sizes",
                payload: AgentPayload.encode(force)))
        return try AgentPayload.decode(StorageInspectionSnapshot.self, from: data)
    }
}
