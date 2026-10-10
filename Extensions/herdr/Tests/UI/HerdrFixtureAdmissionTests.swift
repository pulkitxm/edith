import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
@testable import HerdrUI

@MainActor private final class HerdrFixtureEffects {
    var observers = 0
    var batteryReads = 0
    var constrainedReads = 0
    var trackingReads = 0
    var discoveryStarts = 0
    var constructions = 0

    func worker(_ fixture: WorkerFixtureAdmission?) -> HerdrWorker {
        constructions += 1
        let defaults = HerdrUIDefaults()
        let policy = ExtensionAmbientPolicy(
            jobs: ["sessions.discover": .init(ambient: 30, live: 2)],
            onBattery: {
                self.batteryReads += 1; return true
            },
            constrained: {
                self.constrainedReads += 1; return false
            },
            notificationCenter: NotificationCenter(),
            observeBatteryChanges: { _ in
                self.observers += 1
                return { self.observers -= 1 }
            })
        let store = HerdrStore(
            defaults: defaults,
            liveWatcher: { _ in await MainActor.run { self.discoveryStarts += 1 } },
            machinesProvider: { [] })
        return HerdrWorker(
            store: store, defaults: defaults, ambientPolicy: policy, fixture: fixture,
            trackingDemand: {
                self.trackingReads += 1; return true
            },
            trackingOwnerVersion: { "fixture-v1" }, automaticActions: true)
    }

    var inert: Bool {
        observers == 0 && batteryReads == 0 && constrainedReads == 0 && trackingReads == 0
            && discoveryStarts == 0
    }
}

@MainActor @Suite(.serialized) struct HerdrFixtureAdmissionTests {
    @Test func admittedFixtureAppliesPolicyWithoutAnyPowerOrDiscoveryEffects() async throws {
        let fixture = try EngineFixture(owner: "herdr")
        defer { fixture.remove() }
        let admission = try #require(try fixture.admit())
        let effects = HerdrFixtureEffects()
        let worker = effects.worker(admission)
        #expect(worker.isInertFixture && !worker.automaticActions)
        try worker.applyAmbientPolicy(context: policy(pause: true, subscribers: 1))
        #expect(worker.ambientPolicy.pauseAmbientOnBattery)
        #expect(worker.ambientPolicy.subscribers(for: "sessions.discover") == 1)
        #expect(worker.discoveryInterval == nil)
        await worker.start()
        await worker.refreshDiscoveryDemand()
        try worker.applyAmbientPolicy(context: policy(pause: false, subscribers: 128))
        #expect(!worker.ambientPolicy.pauseAmbientOnBattery && worker.discoveryInterval == nil)
        #expect(effects.inert && effects.constructions == 1)
        await worker.shutdown()
        #expect(effects.inert && HerdrWorkOwnership.pendingCount == 0)
    }

    @Test func actualRuntimeRevalidatesFixtureBeforeEveryPolicySynchronization() async throws {
        let fixture = try EngineFixture(owner: "herdr")
        defer { fixture.remove() }
        let admitted = try #require(try fixture.admit())
        let effects = HerdrFixtureEffects()
        var owned: HerdrWorker?
        let runtime = ExtensionRuntime(
            fixtureAdmission: { _ in try fixture.admit() },
            workerFactory: { _, admission in
                let worker = effects.worker(admission); owned = worker; return worker
            })
        #expect(ok(runtime.execute(request("start", pause: true, subscribers: 1))))
        await owned?.start()
        #expect(effects.inert && effects.constructions == 1 && owned?.discoveryInterval == nil)
        #expect(ok(runtime.execute(request("synchronize", pause: false, subscribers: 128))))
        #expect(owned?.ambientPolicy.pauseAmbientOnBattery == false && effects.inert)
        let marker = admitted.home.appendingPathComponent("worker-fixture.json")
        let original = try Data(contentsOf: marker)
        try Data("{}".utf8).write(to: marker)
        #expect(!ok(runtime.execute(request("synchronize", pause: true, subscribers: 1))))
        #expect(owned?.ambientPolicy.pauseAmbientOnBattery == false && effects.inert)
        try original.write(to: marker)
        #expect(ok(runtime.execute(request("synchronize", pause: true))))
        #expect(owned?.ambientPolicy.pauseAmbientOnBattery == true && effects.inert)
        await stop(runtime)
        #expect(effects.inert && owned?.isStopped == true)
    }

    @Test(arguments: ["missing", "version", "permissions", "symlink", "foreign"])
    func malformedFixtureRejectsBeforeWorkerConstruction(_ mutation: String) async throws {
        let fixture = try EngineFixture(owner: "herdr")
        defer { fixture.remove() }
        let admission = try #require(try fixture.admit())
        let marker = admission.home.appendingPathComponent("worker-fixture.json")
        switch mutation {
        case "missing": try FileManager.default.removeItem(at: marker)
        case "version":
            var object =
                try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
            object["version"] = "2.0.0"
            try JSONSerialization.data(withJSONObject: object).write(to: marker)
        case "permissions":
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: marker.path)
        case "symlink":
            let original = admission.home.appendingPathComponent("original.json")
            try FileManager.default.moveItem(at: marker, to: original)
            try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: original)
        case "foreign":
            var object =
                try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
            object["extensionID"] = "music"
            try JSONSerialization.data(withJSONObject: object).write(to: marker)
        default: Issue.record("Unknown marker mutation")
        }
        let effects = HerdrFixtureEffects()
        let runtime = ExtensionRuntime(
            fixtureAdmission: { _ in try fixture.admit() },
            workerFactory: { _, admission in effects.worker(admission) })
        #expect(!ok(runtime.execute(request("start", pause: false))))
        #expect(effects.constructions == 0 && effects.inert)
        await stop(runtime)
        #expect(effects.constructions == 0 && effects.inert)
    }

    @Test func fixtureCannotBecomeProductionDuringSynchronization() async throws {
        let fixture = try EngineFixture(owner: "herdr")
        defer { fixture.remove() }
        var admitted = try fixture.admit()
        let effects = HerdrFixtureEffects()
        let runtime = ExtensionRuntime(
            fixtureAdmission: { _ in admitted },
            workerFactory: { _, admission in effects.worker(admission) })
        #expect(ok(runtime.execute(request("start", pause: false))))
        admitted = nil
        #expect(!ok(runtime.execute(request("synchronize", pause: true))))
        #expect(!ok(runtime.execute(request("start", pause: true))))
        #expect(effects.inert && effects.constructions == 1)
        await stop(runtime)
    }

    @Test func productionRuntimeStillAttachesOnlyItsInjectedOwnedObservation() async {
        let effects = HerdrFixtureEffects()
        let runtime = ExtensionRuntime(
            fixtureAdmission: { _ in nil },
            workerFactory: { _, admission in effects.worker(admission) })
        let input = request("start", pause: true).mutableCopy() as! NSMutableDictionary
        input["defaultsSuite"] = ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
        input["recoveryOnly"] = true
        #expect(ok(runtime.execute(input)))
        #expect(
            effects.observers == 1 && effects.constructions == 1 && effects.discoveryStarts == 0)
        await stop(runtime)
        #expect(effects.observers == 0 && effects.discoveryStarts == 0)
    }

    private func policy(pause: Bool, subscribers: Int = 0) -> NSDictionary {
        [
            "ambientPolicy": [
                "pauseAmbientOnBattery": pause, "subscribers": ["sessions.discover": subscribers],
            ]
        ]
    }

    private func request(_ operation: String, pause: Bool, subscribers: Int = 0) -> NSDictionary {
        let input =
            policy(pause: pause, subscribers: subscribers).mutableCopy() as! NSMutableDictionary
        input["operation"] = operation
        return input
    }

    private func ok(_ reply: NSObject) -> Bool { (reply as? NSDictionary)?["ok"] as? Bool == true }

    private func stop(_ runtime: ExtensionRuntime) async {
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
    }
}
