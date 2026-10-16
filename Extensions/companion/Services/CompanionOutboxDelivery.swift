import EdithExtensionUI
import EdithExtensionSupport
import Foundation

public actor CompanionOutboxDelivery {
    public static let shared = CompanionOutboxDelivery()
    public static let batchSize = 8

    public typealias Send = @Sendable (URL, CompanionOutboxItem, Data) async throws -> String

    private let directory: URL
    private let send: Send
    private let notify: @Sendable () async -> Void
    private var active: Task<CompanionOutboxDrain, Never>?
    private var cancelled = false
    private var settlement: Task<Void, Never>?

    public init(
        directory: URL = CompanionOutbox.directory,
        send: @escaping Send = { endpoint, item, data in
            try await CompanionClient(baseURL: endpoint).ingestAudio(
                name: item.name, data: data,
                mtime: ISO8601DateFormatter().string(from: item.recordedAt)
            ).status
        },
        notify: @escaping @Sendable () async -> Void = {
            await MainActor.run { IPC.post(CompanionBackgroundOperation.outboxChanged) }
        }
    ) {
        self.directory = directory
        self.send = send
        self.notify = notify
    }

    public func drain(endpoint: URL) async -> CompanionOutboxDrain {
        if let active { return await active.value }
        guard !cancelled else { return CompanionOutboxDrain() }
        let task = makeDeliveryTask(endpoint: endpoint)
        active = task
        let result = await task.value
        if active == task { active = nil }
        return result
    }

    public func enqueue(endpoint: URL) {
        guard active == nil, !cancelled else { return }
        let task = makeDeliveryTask(endpoint: endpoint)
        active = task
        settlement = Task {
            _ = await task.value
            if active == task { active = nil }
            settlement = nil
        }
    }

    public func cancelPending() {
        cancelled = true
        active?.cancel()
    }

    public func cancel() async {
        cancelPending()
        let task = active
        _ = await task?.value
        await settlement?.value
        if active == task { active = nil }
    }

    private func makeDeliveryTask(endpoint: URL) -> Task<CompanionOutboxDrain, Never> {
        let directory = directory
        let send = send
        let notify = notify
        return Task.detached(priority: .utility) {
            let result = await CompanionOutbox.drain(in: directory, limit: Self.batchSize) {
                item, data in
                try await send(endpoint, item, data)
            }
            if !result.isEmpty { await notify() }
            return result
        }
    }
}
