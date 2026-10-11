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

    @Test func malformedFunctionalIntentCannotAdmitOriginalOwner() throws {
        let identifier = "com.pulkit.edith.tests.worker-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: WorkerFixtureError.self) {
            try WorkerFixtureAdmission.admit(
                extensionID: "presenter", context: [:],
                environment: [
                    "EDITH_FUNCTIONAL_FIXTURE": "1", "EDITH_EXTENSION_FIXTURE_HOME": "relative",
                ],
                hostIdentifier: identifier, hostBundle: root.appendingPathComponent("Fixture.app"),
                roleDirectory: root.appendingPathComponent("helper.bundle"),
                roleIdentifier: "com.pulkit.edith.extensions.presenter.helper",
                version: "1.0.0", hostABI: "edith-host-2")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func suspensionClosesStartupAndCommandAdmissionSynchronously() async throws {
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        let runtime = ExtensionRuntime()
        await withCheckedContinuation { continuation in
            runtime.suspendCommands { continuation.resume() }
            #expect(
                (runtime.execute(["operation": "start", "defaultsSuite": suite]) as? NSDictionary)?[
                    "ok"] as? Bool == false)
            var replies = 0
            runtime.invoke([
                "token": UUID().uuidString, "command": "presenter.ui.read",
                "payload": Data("{}".utf8),
            ]) { data, error in
                replies += 1
                #expect(data == nil && error != nil)
            }
            #expect(replies == 1)
        }
        await withCheckedContinuation { continuation in
            runtime.suspendCommands { continuation.resume() }
        }
        #expect(
            (runtime.execute(["operation": "start", "defaultsSuite": suite]) as? NSDictionary)?[
                "ok"] as? Bool == false)
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
