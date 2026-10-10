import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
@testable import WindowSweatersExtension

@MainActor @Suite(.serialized) struct WorkerFixtureEngineTests {
    private func fixture(_ owner: String) throws -> EngineFixture {
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        try #require(suite.hasPrefix("edith.") && suite.contains(".tests."))
        return try EngineFixture(owner: owner)
    }

    @Test func sweaterChangesNeverAttachWindowServer() throws {
        let value = try fixture("windowSweaters"); defer { value.remove() }
        let admission = try #require(try value.admit())
        let engine = SweaterEngine(fixture: admission)
        SharedDefaults.store.set(true, forKey: "windowSweatersActive")
        engine.applySettings()
        #expect(engine.systemResourceCount == 0)
        engine.shutdown()
        #expect(engine.systemResourceCount == 0)
        SharedDefaults.store.removeObject(forKey: "windowSweatersActive")
    }

}
