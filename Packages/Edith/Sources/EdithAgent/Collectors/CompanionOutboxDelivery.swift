import EdithKit
import Foundation

public actor CompanionOutboxDelivery {
    public static let shared = CompanionOutboxDelivery()
    public static let batchSize = 8

    public typealias Send = @Sendable (URL, CompanionOutboxItem, Data) async throws -> String

    private let directory: URL
    private let send: Send
    private let notify: @Sendable () -> Void
    private var active: Task<CompanionOutboxDrain, Never>?

    public init(
        directory: URL = CompanionOutbox.directory,
        send: @escaping Send = { endpoint, item, data in
            try await CompanionClient(baseURL: endpoint).ingestAudio(
                name: item.name, data: data,
                mtime: ISO8601DateFormatter().string(from: item.recordedAt)
            ).status
        },
        notify: @escaping @Sendable () -> Void = {
            IPC.post(CompanionBackgroundOperation.outboxChanged)
        }
    ) {
        self.directory = directory
        self.send = send
        self.notify = notify
    }

    public func drain(endpoint: URL) async -> CompanionOutboxDrain {
        if let active { return await active.value }
        let task = begin(endpoint: endpoint)
        let result = await task.value
        active = nil
        return result
    }

    public func enqueue(endpoint: URL) {
        guard active == nil else { return }
        let task = begin(endpoint: endpoint)
        Task {
            _ = await task.value
            active = nil
        }
    }

    private func begin(endpoint: URL) -> Task<CompanionOutboxDrain, Never> {
        let directory = directory
        let send = send
        let notify = notify
        let task = Task.detached(priority: .utility) {
            let result = await CompanionOutbox.drain(in: directory, limit: Self.batchSize) {
                item, data in
                try await send(endpoint, item, data)
            }
            if !result.isEmpty { notify() }
            return result
        }
        active = task
        return task
    }
}
