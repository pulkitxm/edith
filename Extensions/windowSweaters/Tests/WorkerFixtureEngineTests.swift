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

    @Test func functionalIntentCannotAdmitOriginalOwnerThroughLegacyNamespace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for marker in ["0", "1", "invalid"] {
            #expect(throws: WorkerFixtureError.self) {
                try WorkerFixtureAdmission.admit(
                    extensionID: "windowSweaters", context: [:],
                    environment: ["EDITH_FUNCTIONAL_FIXTURE": marker],
                    hostIdentifier: "com.pulkit.edith",
                    hostBundle: root.appendingPathComponent("Fixture.app"),
                    roleDirectory: root.appendingPathComponent("helper.bundle"),
                    roleIdentifier: "com.pulkit.edith.extensions.windowSweaters.helper",
                    version: "1.0.0", hostABI: "edith-host-2")
            }
        }
        #expect(throws: WorkerFixtureError.self) {
            try WorkerFixtureAdmission.admit(
                extensionID: "windowSweaters", context: ["hostedFunctionalFixture": false],
                environment: [:], hostIdentifier: "com.pulkit.edith",
                hostBundle: root.appendingPathComponent("Fixture.app"),
                roleDirectory: root.appendingPathComponent("helper.bundle"),
                roleIdentifier: "com.pulkit.edith.extensions.windowSweaters.helper",
                version: "1.0.0", hostABI: "edith-host-2")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func presentationDrainJoinsOriginalReadAndClosesAdmission() async throws {
        let suite = "edith.tests.owned-control-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fence = ControlReadReturnFence()
        var reads = 0
        let presentation = ControlPresentation(
            client: nil, defaults: defaults,
            invoke: { operation, _ in
                #expect(operation == "windowSweaters.ui.read")
                reads += 1
                await fence.enterAndWait()
                return Data("{}".utf8)
            })
        let read = Task { await presentation.refresh() }
        await fence.waitForEntry()
        presentation.stop()
        #expect(!presentation.running)
        await presentation.refresh()
        #expect(reads == 1)
        var started = 0, returned = 0
        let first = Task {
            started += 1; await presentation.stopAndWait(); returned += 1
        }
        let second = Task {
            started += 1; await presentation.stopAndWait(); returned += 1
        }
        while started != 2 { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        #expect(returned == 0)
        await fence.release()
        await read.value
        await first.value
        await second.value
        #expect(returned == 2 && reads == 1)
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

private actor ControlReadReturnFence {
    private var entered = false
    private var open = false
    private var entrance: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        entrance?.resume()
        entrance = nil
        if open { return }
        await withCheckedContinuation { pending = $0 }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entrance = $0 }
    }

    func release() {
        open = true
        pending?.resume()
        pending = nil
    }
}
