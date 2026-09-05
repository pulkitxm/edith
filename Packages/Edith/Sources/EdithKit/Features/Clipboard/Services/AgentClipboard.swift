import Foundation

public enum AgentClipboardOperation {
    public static let changedDuringRead = "Clipboard history changed while it was being read."
    public static let capture = "clipboard.capture"
    public static let snapshot = "clipboard.snapshot"
    public static let mutate = "clipboard.mutate"
    public static let blob = "clipboard.blob"
    public static let stats = "clipboard.storageStats"
    public static let internalOperations = [capture, snapshot, mutate, blob, stats]
}

public struct ClipboardCapture: Codable, Sendable {
    public let id: String
    public let data: Data
    public let types: [String]
    public let ext: String
    public let preview: String
    public let sourceApp: String?
    public let sourceBundleID: String?
    public let capturedAt: Date

    public init(
        payload: ClipboardPayload, sourceApp: String?, sourceBundleID: String?,
        id: String = UUID().uuidString, capturedAt: Date = Date()
    ) {
        self.id = id
        data = payload.data
        types = payload.types
        ext = payload.ext
        preview = payload.preview
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.capturedAt = capturedAt
    }
}

public struct ClipboardMutation: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case pin, unpin, delete, copied }
    public let kind: Kind
    public let ids: [String]
    public let copiedAt: Date

    public init(_ kind: Kind, ids: [String], copiedAt: Date = Date()) {
        self.kind = kind
        self.ids = ids
        self.copiedAt = copiedAt
    }
}

public struct ClipboardMutationResult: Codable, Sendable {
    public let changed: Int
    public let total: Int
}

public struct ClipboardSnapshotRequest: Codable, Sendable {
    public let offset: Int
    public let limit: Int
    public let revision: String?

    public init(offset: Int = 0, limit: Int = 256, revision: String? = nil) {
        self.offset = offset
        self.limit = limit
        self.revision = revision
    }
}

public struct ClipboardSnapshot: Codable, Sendable {
    public let entries: [ClipboardEntry]
    public let revision: String
    public let total: Int
}

public struct ClipboardStoredPayload: Codable, Sendable {
    public let entry: ClipboardEntry
    public let data: Data
}

public struct AgentClipboardClient: Sendable {
    private let client: AgentClient
    public init(client: AgentClient = .shared) { self.client = client }

    public func capture(_ capture: ClipboardCapture) async throws -> ClipboardMutationResult {
        try await request(AgentClipboardOperation.capture, capture)
    }

    public func mutate(_ mutation: ClipboardMutation) async throws -> ClipboardMutationResult {
        try await request(AgentClipboardOperation.mutate, mutation)
    }

    public func snapshot(_ query: ClipboardSnapshotRequest = .init()) async throws
        -> ClipboardSnapshot
    {
        try await request(AgentClipboardOperation.snapshot, query)
    }

    public func entries() async throws -> [ClipboardEntry] {
        for attempt in 0..<3 {
            do {
                var page = try await snapshot()
                var entries = page.entries
                while entries.count < page.total {
                    try Task.checkCancellation()
                    page = try await snapshot(
                        .init(offset: entries.count, revision: page.revision))
                    guard !page.entries.isEmpty else {
                        throw AgentError(.failed, "The clipboard snapshot is incomplete.")
                    }
                    entries.append(contentsOf: page.entries)
                }
                return entries
            } catch let error as AgentError
                where error.message == AgentClipboardOperation.changedDuringRead && attempt < 2
            {
                continue
            }
        }
        throw AgentError(.unavailable, "Clipboard history is changing. Try again.")
    }

    public func blob(id: String) async throws -> ClipboardStoredPayload {
        try await request(AgentClipboardOperation.blob, id)
    }

    public func stats() async throws -> ClipboardActions.Stats {
        try await request(AgentClipboardOperation.stats, false)
    }

    private func request<Input: Encodable, Output: Decodable>(
        _ operation: String, _ input: Input
    ) async throws -> Output {
        try Task.checkCancellation()
        return try AgentPayload.decode(
            Output.self,
            from: await client.performInternalAsync(
                operation, payload: AgentPayload.encode(input), timeout: 30))
    }
}
