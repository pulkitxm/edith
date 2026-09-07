import Foundation

public struct ClipboardThumbnailRequest: Codable, Sendable {
    public let id: UUID
    public let entryID: String

    public init(id: UUID = UUID(), entryID: String) {
        self.id = id
        self.entryID = entryID
    }
}

public struct ClipboardThumbnailSnapshot: Codable, Sendable {
    public static let maximumBytes = 128 << 10
    public let data: Data?

    public init(data: Data?) { self.data = data }
}

final class ClipboardPreviewCancellation: @unchecked Sendable {
    static let shared = ClipboardPreviewCancellation()
    private let lock = NSLock()
    private var pending: [UUID: Task<Void, Never>] = [:]

    func cancel(_ id: UUID, send: @escaping @Sendable (String, Data) async throws -> Data) {
        lock.withLock {
            guard pending[id] == nil, pending.count < 64 else { return }
            pending[id] = Task.detached(priority: .utility) { [weak self] in
                defer { self?.finish(id) }
                for attempt in 0..<2 {
                    do {
                        try Task.checkCancellation()
                        _ = try await send(
                            AgentClipboardOperation.cancelThumbnail, AgentPayload.encode(id))
                        return
                    } catch {
                        guard attempt == 0 else { return }
                    }
                }
            }
        }
    }

    private func finish(_ id: UUID) { lock.withLock { pending[id] = nil } }

    deinit { for task in pending.values { task.cancel() } }
}
