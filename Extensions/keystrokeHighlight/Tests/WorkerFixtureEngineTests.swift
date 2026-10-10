import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
@testable import KeystrokeHighlightExtension

@MainActor @Suite(.serialized) struct WorkerFixtureEngineTests {
    private func fixture(_ owner: String) throws -> EngineFixture {
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        try #require(suite.hasPrefix("edith.") && suite.contains(".tests."))
        return try EngineFixture(owner: owner)
    }

    @Test func keystrokeStartupNeverRegistersCaptureOrPanel() throws {
        let value = try fixture("keystrokeHighlight"); defer { value.remove() }
        let admission = try #require(try value.admit())
        let engine = KeystrokeHighlightRuntime(fixture: admission)
        #expect(engine.systemResourceCount == 0)
        #expect(engine.entries.isEmpty)
        engine.syncSettings()
        #expect(engine.systemResourceCount == 0)
        engine.shutdown()
        #expect(engine.systemResourceCount == 0)
    }
}
