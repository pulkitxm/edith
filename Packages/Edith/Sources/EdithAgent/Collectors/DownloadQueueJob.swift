import EdithKit
import Foundation

public struct DownloadQueueSnapshot: Codable, Equatable, Sendable {
    public let readAt: Date
    public let queued: Int
    public let running: Int
    public let finished: Int
    public let failed: Int

    public init(readAt: Date, queued: Int, running: Int, finished: Int, failed: Int) {
        self.readAt = readAt
        self.queued = queued
        self.running = running
        self.finished = finished
        self.failed = failed
    }

    public var pending: Int { queued + running }
}

public enum DownloadQueueTally {
    public static func snapshot(
        records: [DownloadRecord], now: Date = Date()
    ) -> DownloadQueueSnapshot {
        var queued = 0
        var running = 0
        var finished = 0
        var failed = 0
        for record in records {
            switch record.status {
            case .queued: queued += 1
            case .resolving, .downloading: running += 1
            case .done: finished += 1
            case .error, .interrupted: failed += 1
            }
        }
        return DownloadQueueSnapshot(
            readAt: now, queued: queued, running: running, finished: finished, failed: failed)
    }
}

public final class DownloadQueueJob: @unchecked Sendable {
    private let store: AgentStore?
    private let load: @Sendable () -> [DownloadRecord]

    public init(
        store: AgentStore?,
        load: @escaping @Sendable () -> [DownloadRecord] = { DownloadQueue.load() }
    ) {
        self.store = store
        self.load = load
    }

    public func run() async throws -> Data? {
        let records = load()
        let snapshot = DownloadQueueTally.snapshot(records: records)
        try? record(records, at: snapshot.readAt)
        return try AgentPayload.encode(snapshot)
    }

    private func record(_ records: [DownloadRecord], at date: Date) throws {
        guard let store else { return }
        try store.write { database in
            try database.execute(sql: "DELETE FROM download_item")
            for item in records {
                let payload = try AgentPayload.encode(item)
                try database.execute(
                    sql: """
                        INSERT INTO download_item (id, queuedAt, status, payload)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        item.id.uuidString, item.createdAt, item.state, payload,
                    ])
            }
        }
    }
}
