import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct UsageDaemonIntegrationTests {
    @Test func realUsageSchemaAggregatesEveryModelAndSource() throws {
        let rows = try UsageDocumentReader.rows(from: [
            "daily": [
                [
                    "period": "2026-09-04",
                    "bySource": [
                        "local": [
                            ["cost": 1.25, "inputTokens": 100, "outputTokens": 20],
                            ["cost": 0.1, "inputTokens": 30, "outputTokens": 4],
                        ],
                        "machine:work": [["cost": 2.35, "inputTokens": 500, "outputTokens": 70]],
                    ],
                ]
            ]
        ])
        #expect(
            rows == [
                UsageDayRow(
                    day: "2026-09-04", source: "all", costCents: 370, inputTokens: 630,
                    outputTokens: 94)
            ])
    }

    @Test func unsupportedTotalsDoNotTrapOrPublishZeroUsage() {
        for value in [Double.infinity, Double.nan, -1, Double(Int.max)] {
            #expect(throws: (any Error).self) {
                try UsageDocumentReader.rows(from: [
                    "daily": [["period": "2026-09-04", "bySource": ["local": [["cost": value]]]]]
                ])
            }
        }
    }

    @Test func aRefreshAtomicallyReplacesTheDaemonDailyCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentStore(url: root.appendingPathComponent("store.sqlite"), build: "test")
        let document = root.appendingPathComponent("usage.json")
        let snapshot = UsageTopicSnapshot(
            refreshedAt: Date(), seconds: 0, days: 1, totalCostCents: 1, failure: nil)
        try UsageStoreWriter.record(
            snapshot,
            days: [
                UsageDayRow(
                    day: "old", source: "all", costCents: 1, inputTokens: 1, outputTokens: 1)
            ],
            store: store)
        try Data(
            #"{"daily":[{"period":"2026-09-04","bySource":{"local":[{"cost":2.5,"inputTokens":80,"outputTokens":10}]}}]}"#
                .utf8
        )
        .write(to: document)
        let job = UsageCollectorJob(
            store: store, documentURL: document, notifies: false,
            runner: { UsageRefreshResult(events: [], seconds: 0.5, startedAt: Date()) })
        let data = try #require(try await job.run())
        let result = try AgentPayload.decode(UsageTopicSnapshot.self, from: data)
        #expect(result.failure == nil)
        #expect(result.totalCostCents == 250)
        let days = try store.read { try String.fetchAll($0, sql: "SELECT day FROM usage_day") }
        #expect(days == ["2026-09-04"])
    }

    @Test func databaseFailureIsPublishedAsFailureInsteadOfSuccessfulRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentStore(url: root.appendingPathComponent("store.sqlite"), build: "test")
        let document = root.appendingPathComponent("usage.json")
        try Data(#"{"daily":[]}"#.utf8).write(to: document)
        try store.close()
        let job = UsageCollectorJob(
            store: store, documentURL: document, notifies: false,
            runner: { UsageRefreshResult(events: [], seconds: 0, startedAt: Date()) })
        let data = try #require(try await job.run())
        #expect(try AgentPayload.decode(UsageTopicSnapshot.self, from: data).failure != nil)
    }

    @Test func rateLimitBackoffSurvivesAnotherRefreshRequest() async {
        let session = LimitsRefreshSession()
        let now = Date()
        guard case .collect = await session.begin(force: false, now: now) else {
            Issue.record("Expected initial collection")
            return
        }
        let snapshot = LimitsTopicSnapshot(refreshedAt: now, providers: [], failure: "Rate limited")
        await session.finish(snapshot, retryNotBefore: now.addingTimeInterval(300))
        guard
            case .cached(let cached) = await session.begin(
                force: false, now: now.addingTimeInterval(100))
        else {
            Issue.record("Expected retained backoff")
            return
        }
        #expect(cached == snapshot)
        guard case .collect = await session.begin(force: false, now: now.addingTimeInterval(301))
        else {
            Issue.record("Expected collection after backoff")
            return
        }
        await session.finish(snapshot, retryNotBefore: nil)
    }

    @Test func concurrentLimitsRequestsShareTheOriginalCollection() async {
        let session = LimitsRefreshSession()
        let now = Date()
        guard case .collect = await session.begin(force: false, now: now) else {
            Issue.record("Expected initial collection")
            return
        }
        let follower = Task { await session.begin(force: true, now: now) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await session.followerCount == 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(await session.followerCount == 1)
        let snapshot = LimitsTopicSnapshot(refreshedAt: now, providers: [], failure: nil)
        await session.finish(snapshot, retryNotBefore: now.addingTimeInterval(100))
        let result = await follower.value
        switch result {
        case .cached(let cached): #expect(cached == snapshot)
        case .collect: Issue.record("Concurrent request started duplicate collection")
        }
    }

    @Test func aForcedRefreshBypassesBackoff() async {
        let session = LimitsRefreshSession()
        let now = Date()
        _ = await session.begin(force: false, now: now)
        let snapshot = LimitsTopicSnapshot(refreshedAt: now, providers: [], failure: "Rate limited")
        await session.finish(snapshot, retryNotBefore: now.addingTimeInterval(300))
        guard case .collect = await session.begin(force: true, now: now) else {
            Issue.record("Expected forced collection")
            return
        }
        await session.finish(snapshot, retryNotBefore: nil)
    }
}
