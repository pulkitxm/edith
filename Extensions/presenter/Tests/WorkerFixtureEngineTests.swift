import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
@testable import PresenterExtension

@MainActor @Suite(.serialized) struct WorkerFixtureEngineTests {
    private func fixture(_ owner: String) throws -> EngineFixture {
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        try #require(suite.hasPrefix("edith.") && suite.contains(".tests."))
        return try EngineFixture(owner: owner)
    }

    @Test func presenterNeverDiscoversActualSessionsOrWindows() throws {
        let value = try fixture("presenter"); defer { value.remove() }
        let admission = try #require(try value.admit())
        SharedDefaults.store.set(true, forKey: AppStorageKeys.Presenter.autoEnabled)
        let engine = PresenterDetector(fixture: admission)
        engine.applySettings()
        engine.applyScan(engine.scanner.scan())
        #expect(!engine.publishedActive)
        #expect(engine.systemResourceCount == 0)
        engine.shutdown()
        #expect(engine.systemResourceCount == 0)
        SharedDefaults.store.removeObject(forKey: AppStorageKeys.Presenter.autoEnabled)
    }

}
