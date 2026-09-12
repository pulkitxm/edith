import Foundation
import Testing

@testable import EdithKit

@Suite struct UsageRefreshCorrelationTests {
    @Test func queuedRunWaitsForItsOwnResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = UsageRefreshSink(dataDir: directory, startedAt: Date())
        older.begin()
        older.write(.finished(seconds: 1))
        older.finish()
        let runID = UUID().uuidString
        let follower = Task {
            try await UsageRefreshFollower.follow(
                dataDir: directory, runID: runID, startTimeout: 2,
                pollInterval: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        let requested = UsageRefreshSink(dataDir: directory, startedAt: Date(), runID: runID)
        requested.begin()
        requested.write(.finished(seconds: 7))
        requested.finish()
        let next = UsageRefreshSink(dataDir: directory, startedAt: Date())
        next.begin()
        next.write(.finished(seconds: 9))
        next.finish()
        let result = try await follower.value
        #expect(result.seconds == 7)
    }

    @Test func failedQueuedRunDoesNotReturnPreviousSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runID = UUID().uuidString
        UsageRefreshRunner.recordFailure("fixture startup failed", runID: runID, dataDir: directory)
        await #expect(throws: UsageRefreshFailure.reported("fixture startup failed")) {
            try await UsageRefreshFollower.follow(dataDir: directory, runID: runID)
        }
    }

    @Test func abandonedRequestTimesOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        await #expect(
            throws: UsageRefreshFailure.reported("the requested usage refresh did not start")
        ) {
            try await UsageRefreshFollower.follow(
                dataDir: directory, runID: UUID().uuidString, startTimeout: 0)
        }
    }
}
