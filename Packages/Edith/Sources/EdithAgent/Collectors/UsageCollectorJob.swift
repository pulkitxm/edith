import EdithKit
import Foundation

public enum UsageStoreWriter {
    public static func record(
        _ snapshot: UsageTopicSnapshot, days: [UsageDayRow], store: AgentStore?
    ) throws {
        guard let store else { throw AgentStoreError("The usage store is unavailable.") }
        try store.write { database in
            try database.execute(sql: "DELETE FROM usage_day")
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
    public static func days(at url: URL) throws -> [UsageDayRow] {
        guard
            let data = try UsageDataFiles.readRegularFile(
                at: url, maximumBytes: UsageDataFiles.maximumUsageDocumentBytes),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AgentStoreError("The usage document is unavailable.") }
        return try rows(from: root)
    }

    public static func rows(from root: [String: Any]) throws -> [UsageDayRow] {
        guard let daily = root["daily"] as? [[String: Any]] else {
            throw AgentStoreError("The usage document has no daily history.")
        }
        return try daily.map { entry in
            guard let day = entry["period"] as? String,
                let sources = entry["bySource"] as? [String: [[String: Any]]]
            else { throw AgentStoreError("A usage day is malformed.") }
            let models = sources.values.flatMap { $0 }
            let cost = models.reduce(0.0) { $0 + ($1["cost"] as? Double ?? 0) }
            let input = models.reduce(0.0) { $0 + ($1["inputTokens"] as? Double ?? 0) }
            let output = models.reduce(0.0) { $0 + ($1["outputTokens"] as? Double ?? 0) }
            guard
                [cost * 100, input, output].allSatisfy({
                    $0.isFinite && $0 >= 0 && $0.rounded() < Double(Int.max)
                })
            else { throw AgentStoreError("A usage total is outside the supported range.") }
            return UsageDayRow(
                day: day, source: "all",
                costCents: Int((cost * 100).rounded()),
                inputTokens: Int(input.rounded()), outputTokens: Int(output.rounded()))
        }
    }
}

public actor UsageMachineRefreshRequests {
    public struct Request: Equatable, Sendable {
        public let runID: String
        public var machinePolicy: UsageMachineRefreshPolicy
    }

    public static let shared = UsageMachineRefreshRequests()
    private var pending: Request?

    public init() {}

    @discardableResult
    public func enqueue(_ policy: UsageMachineRefreshPolicy) -> String {
        if var request = pending {
            if request.machinePolicy.rawValue < policy.rawValue {
                request.machinePolicy = policy
                pending = request
            }
            return request.runID
        }
        let request = Request(runID: UUID().uuidString, machinePolicy: policy)
        pending = request
        return request.runID
    }

    public func take() -> Request {
        defer { pending = nil }
        return pending ?? Request(runID: UUID().uuidString, machinePolicy: .due)
    }

    public func discard(_ runID: String) {
        if pending?.runID == runID { pending = nil }
    }
}

public final class UsageCollectorJob: @unchecked Sendable {
    private let store: AgentStore?
    private let runner: @Sendable () async throws -> UsageRefreshResult
    private let documentURL: URL
    private let notifies: Bool

    public init(
        store: AgentStore?,
        documentURL: URL = Repo.usageJSON,
        notifies: Bool = true,
        runner: @escaping @Sendable () async throws -> UsageRefreshResult = {
            let request = await UsageMachineRefreshRequests.shared.take()
            let deadline = ContinuousClock.now.advanced(by: .seconds(900))
            do {
                while true {
                    try Task.checkCancellation()
                    do {
                        return try await UsageRefreshRunner.run(
                            machinePolicy: request.machinePolicy, runID: request.runID)
                    } catch UsageRefreshFailure.busy {
                        if ContinuousClock.now >= deadline {
                            UsageRefreshRunner.recordFailure(
                                UsageRefreshFailure.timedOut.localizedDescription,
                                runID: request.runID)
                            throw UsageRefreshFailure.timedOut
                        }
                    }
                    try await Task.sleep(for: .milliseconds(150))
                }
            } catch is CancellationError {
                UsageRefreshRunner.recordFailure(
                    "Usage collection cancelled.", runID: request.runID)
                throw CancellationError()
            }
        }
    ) {
        self.store = store
        self.documentURL = documentURL
        self.notifies = notifies
        self.runner = runner
    }

    private func announce(_ name: Notification.Name) {
        guard notifies else { return }
        IPC.post(name)
    }

    public func run() async throws -> Data? {
        let startedAt = Date()
        announce(IPC.Name.usageRefreshStarted)
        defer { announce(IPC.Name.usageRefreshFinished) }
        do {
            let result = try await runner()
            let days = try UsageDocumentReader.days(at: documentURL)
            let total = try days.reduce(0) { sum, day in
                let (value, overflow) = sum.addingReportingOverflow(day.costCents)
                guard !overflow else { throw AgentStoreError("The usage total is too large.") }
                return value
            }
            let snapshot = UsageTopicSnapshot(
                refreshedAt: startedAt, seconds: result.seconds, days: days.count,
                totalCostCents: total, failure: nil)
            try UsageStoreWriter.record(snapshot, days: days, store: store)
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
