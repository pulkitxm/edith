import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
@testable import HingeExtension

@MainActor @Suite(.serialized) struct WorkerFixtureEngineTests {
    private func fixture(_ owner: String) throws -> EngineFixture {
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        try #require(suite.hasPrefix("edith.") && suite.contains(".tests."))
        return try EngineFixture(owner: owner)
    }

    @Test func fixtureEngineNeverCreatesTheLiveDesktop() throws {
        let value = try fixture("hinge"); defer { value.remove() }
        let admission = try #require(try value.admit())
        SharedDefaults.store.set(true, forKey: HingeState.enabledKey)
        let engine = HingeEngine(fixture: admission)
        defer {
            engine.shutdown(); HingeState.setActive(false);
            SharedDefaults.store.removeObject(forKey: HingeState.enabledKey)
        }
        #expect(engine.systemResourceCount == 0)
        HingeState.setActive(true)
        engine.applySettings()
        #expect(HingeState.isActive())
        #expect(engine.systemResourceCount == 0)
        engine.shutdown()
        #expect(engine.systemResourceCount == 0)
    }

}
