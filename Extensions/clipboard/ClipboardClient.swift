import Foundation

public enum ClipboardServiceOperation {
    public static let changedDuringRead = "Clipboard history changed while it was being read."
    public static let capture = "clipboard.capture"
    public static let snapshot = "clipboard.snapshot"
    public static let mutate = "clipboard.mutate"
    public static let blob = "clipboard.blob"
    public static let stats = "clipboard.storageStats"
    public static let copy = "clipboard.copyPayload"
    public static let inspect = "clipboard.inspect"
    public static let thumbnail = "clipboard.thumbnail"
    public static let cancelThumbnail = "clipboard.thumbnail.cancel"
    public static let internalOperations = [
        capture, snapshot, mutate, blob, stats, thumbnail, cancelThumbnail, copy, inspect,
    ]
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
    public let recentlyCreated: Bool

    public init(
        offset: Int = 0, limit: Int = 256, revision: String? = nil,
        recentlyCreated: Bool = false
    ) {
        self.offset = offset
        self.limit = limit
        self.revision = revision
        self.recentlyCreated = recentlyCreated
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

public struct ClipboardClient: Sendable {
    private let send: @Sendable (String, Data) async throws -> Data

    public init(service: ClipboardService) {
        send = { try await service.perform(operation: $0, payload: $1) }
    }

    public init(send: @escaping @Sendable (String, Data) async throws -> Data) {
        self.send = send
    }

    public func capture(_ capture: ClipboardCapture) async throws -> ClipboardMutationResult {
        try await request(ClipboardServiceOperation.capture, capture)
    }

    public func mutate(_ mutation: ClipboardMutation) async throws -> ClipboardMutationResult {
        try await request(ClipboardServiceOperation.mutate, mutation)
    }

    public func snapshot(_ query: ClipboardSnapshotRequest = .init()) async throws
        -> ClipboardSnapshot
    {
        try await request(ClipboardServiceOperation.snapshot, query)
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
                        throw ClipboardServiceError(
                            .failed, "The clipboard snapshot is incomplete.")
                    }
                    entries.append(contentsOf: page.entries)
                }
                return entries
            } catch let error as ClipboardServiceError
                where error.message == ClipboardServiceOperation.changedDuringRead && attempt < 2
            {
                continue
            }
        }
        throw ClipboardServiceError(.unavailable, "Clipboard history is changing. Try again.")
    }

    public func blob(id: String) async throws -> ClipboardStoredPayload {
        try await request(ClipboardServiceOperation.blob, id)
    }

    public func copy(id: String, plainTextOnly: Bool = false) async throws -> ClipboardCopyPayload {
        try await request(
            ClipboardServiceOperation.copy,
            ClipboardCopyRequest(id: id, plainTextOnly: plainTextOnly)
        )
    }

    public func inspect() async throws -> ClipboardInspection {
        try await request(ClipboardServiceOperation.inspect, false)
    }

    public func thumbnail(id: String) async throws -> ClipboardThumbnailSnapshot {
        let query = ClipboardThumbnailRequest(entryID: id)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: ClipboardThumbnailSnapshot = try await request(
                ClipboardServiceOperation.thumbnail, query)
            try Task.checkCancellation()
            guard (result.data?.count ?? 0) <= ClipboardThumbnailSnapshot.maximumBytes else {
                throw ClipboardServiceError(
                    .failed, "The clipboard preview exceeds its resource limit.")
            }
            return result
        } onCancel: {
            ClipboardPreviewCancellation.shared.cancel(query.id, send: send)
        }
    }

    public func stats() async throws -> ClipboardActions.Stats {
        try await request(ClipboardServiceOperation.stats, false)
    }

    private func request<Input: Encodable, Output: Decodable>(
        _ operation: String, _ input: Input
    ) async throws -> Output {
        try Task.checkCancellation()
        return try ClipboardMessage.decode(
            Output.self,
            from: await send(operation, ClipboardMessage.encode(input)))
    }
}
