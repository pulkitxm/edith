import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
@testable import FocusDimExtension

@MainActor @Suite(.serialized) struct WorkerFixtureEngineTests {
    private func fixture(_ owner: String) throws -> EngineFixture {
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        try #require(suite.hasPrefix("edith.") && suite.contains(".tests."))
        return try EngineFixture(owner: owner)
    }

    @Test func focusChangesNeverCreateDesktopOverlays() throws {
        let value = try fixture("focusDim"); defer { value.remove() }
        let admission = try #require(try value.admit())
        SharedDefaults.store.set(true, forKey: FocusDimState.enabledKey)
        let engine = FocusDimEngine(fixture: admission)
        defer {
            engine.shutdown(); FocusDimState.setActive(false);
            SharedDefaults.store.removeObject(forKey: FocusDimState.enabledKey)
        }
        #expect(engine.systemResourceCount == 0)
        FocusDimState.setActive(true)
        engine.applySettings()
        #expect(FocusDimState.isActive())
        #expect(engine.systemResourceCount == 0)
        engine.shutdown()
        #expect(engine.systemResourceCount == 0)
    }

}
