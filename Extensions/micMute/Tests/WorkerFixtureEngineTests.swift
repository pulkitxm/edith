import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
@testable import MicMuteExtension

@MainActor @Suite(.serialized) struct WorkerFixtureEngineTests {
    private func fixture(_ owner: String) throws -> EngineFixture {
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        try #require(suite.hasPrefix("edith.") && suite.contains(".tests."))
        return try EngineFixture(owner: owner)
    }

    @Test func microphoneUsesOwnedControlAndRestoresOnStop() throws {
        let value = try fixture("micMute"); defer { value.remove() }
        let admission = try #require(try value.admit())
        SharedDefaults.store.set(false, forKey: AppStorageKeys.Mic.muted)
        let engine = MicMuteEngine(fixture: admission)
        #expect(engine.systemResourceCount == 0)
        engine.setMuted(true)
        #expect(engine.muted)
        #expect(engine.fixtureMicrophoneValue == 1)
        engine.syncSettings()
        #expect(engine.systemResourceCount == 0)
        engine.shutdown()
        #expect(engine.fixtureMicrophoneValue == 0)
        #expect(engine.systemResourceCount == 0)
        engine.setMuted(false)
        #expect(engine.muted)
        SharedDefaults.store.removeObject(forKey: AppStorageKeys.Mic.muted)
    }

}
