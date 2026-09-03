import EdithKit
import Foundation

public struct UsageTopicSnapshot: Codable, Equatable, Sendable {
    public let refreshedAt: Date
    public let seconds: Double
    public let days: Int
    public let totalCostCents: Int
    public let failure: String?

    public init(
        refreshedAt: Date, seconds: Double, days: Int, totalCostCents: Int, failure: String?
    ) {
        self.refreshedAt = refreshedAt
        self.seconds = seconds
        self.days = days
        self.totalCostCents = totalCostCents
        self.failure = failure
    }
}

public enum UsageStoreWriter {
    public static func record(
        _ snapshot: UsageTopicSnapshot, days: [UsageDayRow], store: AgentStore?
    ) throws {
        guard let store else { return }
        try store.write { database in
            for day in days {
                try database.execute(
                    sql: """
                        INSERT INTO usage_day (day, source, costCents, inputTokens, \
                        outputTokens, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(day) DO UPDATE SET source = excluded.source,
                        costCents = excluded.costCents, inputTokens = excluded.inputTokens,
                        outputTokens = excluded.outputTokens, updatedAt = excluded.updatedAt
                        """,
                    arguments: [
                        day.day, day.source, day.costCents, day.inputTokens, day.outputTokens,
                        snapshot.refreshedAt,
                    ])
            }
        }
    }
}

public struct UsageDayRow: Equatable, Sendable {
    public let day: String
    public let source: String
    public let costCents: Int
    public let inputTokens: Int
    public let outputTokens: Int

    public init(
        day: String, source: String, costCents: Int, inputTokens: Int, outputTokens: Int
    ) {
        self.day = day
        self.source = source
        self.costCents = costCents
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum UsageDocumentReader {
    public static func days(at url: URL) -> [UsageDayRow] {
        guard let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return rows(from: root)
    }

    public static func rows(from root: [String: Any]) -> [UsageDayRow] {
        guard let daily = root["daily"] as? [[String: Any]] else { return [] }
        return daily.compactMap { entry in
            guard let day = entry["date"] as? String else { return nil }
            let cost = entry["totalCost"] as? Double ?? 0
            return UsageDayRow(
                day: day, source: entry["source"] as? String ?? "all",
                costCents: Int((cost * 100).rounded()),
                inputTokens: entry["inputTokens"] as? Int ?? 0,
                outputTokens: entry["outputTokens"] as? Int ?? 0)
        }
    }
}

public final class UsageCollectorJob: @unchecked Sendable {
    private let store: AgentStore?
    private let runner: @Sendable () async throws -> UsageRefreshResult
    private let documentURL: URL

    public init(
        store: AgentStore?,
        documentURL: URL = Repo.usageJSON,
        runner: @escaping @Sendable () async throws -> UsageRefreshResult = {
            try await UsageRefreshRunner.run()
        }
    ) {
        self.store = store
        self.documentURL = documentURL
        self.runner = runner
    }

    public func run() async throws -> Data? {
        let startedAt = Date()
        do {
            let result = try await runner()
            let days = UsageDocumentReader.days(at: documentURL)
            let snapshot = UsageTopicSnapshot(
                refreshedAt: startedAt, seconds: result.seconds, days: days.count,
                totalCostCents: days.reduce(0) { $0 + $1.costCents }, failure: nil)
            try? UsageStoreWriter.record(snapshot, days: days, store: store)
            return try AgentPayload.encode(snapshot)
        } catch UsageRefreshFailure.busy {
            return nil
        } catch {
            let snapshot = UsageTopicSnapshot(
                refreshedAt: startedAt, seconds: Date().timeIntervalSince(startedAt),
                days: 0, totalCostCents: 0, failure: error.localizedDescription)
            return try AgentPayload.encode(snapshot)
        }
    }
}
