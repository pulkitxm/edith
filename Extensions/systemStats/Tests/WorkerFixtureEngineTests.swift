import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
@testable import SystemStatsExtension

@MainActor @Suite(.serialized) struct WorkerFixtureEngineTests {
    private func fixture(_ owner: String) throws -> EngineFixture {
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        try #require(suite.hasPrefix("edith.") && suite.contains(".tests."))
        return try EngineFixture(owner: owner)
    }

    @Test func metricsUseSyntheticSnapshotWithoutMenuOrTimer() throws {
        let value = try fixture("systemStats"); defer { value.remove() }
        let admission = try #require(try value.admit())
        let engine = SystemStatsStatusItem(fixture: admission)
        #expect(engine.snapshot.cpu == 12)
        #expect(engine.snapshot.memory == 34)
        #expect(engine.systemResourceCount == 0)
        engine.shutdown()
        #expect(engine.systemResourceCount == 0)
    }

}
