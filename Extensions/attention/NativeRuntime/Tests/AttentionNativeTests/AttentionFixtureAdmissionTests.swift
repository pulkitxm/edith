import Darwin
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
import EdithExtensionSupport_attention_native

@testable import AttentionNative

@MainActor
struct AttentionIssuedFixture {
    let issued: EngineFixture
    let admission: WorkerFixtureAdmission
    let context: NSDictionary
    private let previous: [String: String?]

    init() throws {
        let issued = try EngineFixture(owner: "attention")
        let admission = try #require(try issued.admit())
        let marker = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: admission.home.appendingPathComponent("worker-fixture.json"))
            ) as? [String: Any])
        let identifier = try #require(marker["hostIdentifier"] as? String)
        self.issued = issued
        self.admission = admission
        context = [
            "hostIdentifier": identifier, "defaultsSuite": identifier + ".extensions.attention",
            "dataDirectory": admission.dataDirectory.path,
        ]
        let environment = [
            "EDITH_EXTENSION_FIXTURE_HOME": admission.home.path,
            "EDITH_EXTENSION_DATA_ROOT": admission.dataDirectory.path,
            "EDITH_SHARED_DEFAULTS_SUITE": identifier + ".extensions.attention",
            "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": "attention",
        ]
        var saved: [String: String?] = [:]
        for (key, value) in environment {
            saved[key] = .some(ProcessInfo.processInfo.environment[key])
            setenv(key, value, 1)
        }
        previous = saved
    }

    func admit(_ input: NSDictionary) throws -> WorkerFixtureAdmission? {
        for key in ["hostIdentifier", "defaultsSuite", "dataDirectory"] {
            guard input[key] as? String == context[key] as? String else {
                throw WorkerFixtureError.invalid
            }
        }
        return try issued.admit()
    }

    func input(operation: String) -> NSMutableDictionary {
        let result = NSMutableDictionary(dictionary: context as! [AnyHashable: Any])
        result["operation"] = operation
        result["ambientPolicy"] = [
            "pauseAmbientOnBattery": true, "subscribers": ["attention.ingest": 0],
        ]
        return result
    }

    func remove() {
        for (key, value) in previous {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        issued.remove()
    }
}

@MainActor @Suite(.serialized)
struct AttentionFixtureAdmissionTests {
    @Test func invalidFixtureHintsRejectBeforeDatabaseOrObserverStartup() throws {
        let fixture = try AttentionIssuedFixture()
        defer { fixture.remove() }
        let controller = AttentionExtensionController(bundle: .main)
        #expect(
            (controller.execute(fixture.input(operation: "start")) as? NSDictionary)?["ok"] as? Bool
                == false)
        #expect(
            (controller.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.admission.dataDirectory.appendingPathComponent(
                    "attention-history.sqlite"
                ).path))
    }

    @Test func issuedFixtureKeepsAutomaticMaintenanceAndPowerObservationInert() async throws {
        let fixture = try AttentionIssuedFixture()
        defer { fixture.remove() }
        let previousRoot = AttentionPaths.root
        defer { AttentionPaths.root = previousRoot }
        var observations = 0
        var explicitCalls = 0
        let policy = ExtensionAmbientPolicy(
            jobs: ["attention.ingest": .init(ambient: 900, live: 900)], onBattery: { true },
            constrained: { false }, notificationCenter: NotificationCenter(),
            observeBatteryChanges: { _ in
                observations += 1; return {}
            })
        let controller = AttentionExtensionController(
            bundle: .main, notifySettingsChanged: { explicitCalls += 1 },
            admitFixture: fixture.admit, ambientPolicy: policy)
        #expect(
            (controller.execute(fixture.input(operation: "start")) as? NSDictionary)?["ok"] as? Bool
                == true)
        await Task.yield()
        #expect(observations == 0)
        let sync = fixture.input(operation: "synchronize")
        sync["ambientPolicyOnly"] = true
        #expect((controller.execute(sync) as? NSDictionary)?["ok"] as? Bool == true)
        #expect(explicitCalls == 0 && observations == 0)
        sync["defaultsSuite"] = "invalid"
        #expect((controller.execute(sync) as? NSDictionary)?["ok"] as? Bool == false)
        await withCheckedContinuation { continuation in
            controller.prepareToStop { continuation.resume() }
        }
        #expect(
            (controller.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
        #expect(observations == 0)
    }

    @Test func tamperedMarkerCannotCreateDatabaseOrRegisterPowerObserver() throws {
        let fixture = try AttentionIssuedFixture()
        defer { fixture.remove() }
        try Data("{}".utf8).write(
            to: fixture.admission.home.appendingPathComponent("worker-fixture.json"))
        let controller = AttentionExtensionController(
            bundle: .main, notifySettingsChanged: {}, admitFixture: fixture.admit)
        #expect(
            (controller.execute(fixture.input(operation: "start")) as? NSDictionary)?["ok"] as? Bool
                == false)
        #expect(
            (controller.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.admission.dataDirectory.appendingPathComponent(
                    "attention-history.sqlite"
                ).path))
    }
}
