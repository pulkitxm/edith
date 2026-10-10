import Darwin
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport

@testable import UsageExtension

@MainActor
struct UsageIssuedFixture {
    let issued: EngineFixture
    let admission: WorkerFixtureAdmission
    let context: NSDictionary
    private let previous: [String: String?]

    init() throws {
        let issued = try EngineFixture(owner: "usage")
        let admission = try #require(try issued.admit())
        let marker = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: admission.home.appendingPathComponent("worker-fixture.json"))
            ) as? [String: Any])
        let identifier = try #require(marker["hostIdentifier"] as? String)
        self.issued = issued
        self.admission = admission
        context = [
            "hostIdentifier": identifier, "defaultsSuite": identifier + ".extensions.usage",
            "dataDirectory": admission.dataDirectory.path,
        ]
        let environment = [
            "EDITH_EXTENSION_FIXTURE_HOME": admission.home.path,
            "EDITH_EXTENSION_DATA_ROOT": admission.dataDirectory.path,
            "EDITH_SHARED_DEFAULTS_SUITE": identifier + ".extensions.usage",
            "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": "usage",
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
            "pauseAmbientOnBattery": true, "subscribers": ["usage.refresh": 0, "usage.limits": 0],
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
struct UsageFixtureAdmissionTests {
    @Test func broadFixtureHintIsRejectedBeforeAnyOwnedEngineStarts() throws {
        let fixture = try UsageIssuedFixture()
        defer { fixture.remove() }
        let runtime = ExtensionRuntime()
        #expect(
            (runtime.execute(fixture.input(operation: "start")) as? NSDictionary)?["ok"] as? Bool
                == false)
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
        #expect(!FileManager.default.fileExists(atPath: Repo.usageJSON.path))
    }

    @Test func sealedFixtureStartsWithoutAutomaticCollectorsAndRejectsChangedContext() async throws
    {
        let fixture = try UsageIssuedFixture()
        defer { fixture.remove() }
        let runtime = ExtensionRuntime(admitFixture: fixture.admit)
        #expect(
            (runtime.execute(fixture.input(operation: "start")) as? NSDictionary)?["ok"] as? Bool
                == true)
        let sync = fixture.input(operation: "synchronize")
        sync["ambientPolicyOnly"] = true
        #expect((runtime.execute(sync) as? NSDictionary)?["ok"] as? Bool == true)
        sync["dataDirectory"] = fixture.admission.home.path
        #expect((runtime.execute(sync) as? NSDictionary)?["ok"] as? Bool == false)
        #expect(!FileManager.default.fileExists(atPath: Repo.usageJSON.path))
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
    }

    @Test func markerTamperingIsRejectedBeforeRuntimeStartup() throws {
        let fixture = try UsageIssuedFixture()
        defer { fixture.remove() }
        try Data("{}".utf8).write(
            to: fixture.admission.home.appendingPathComponent("worker-fixture.json"))
        let runtime = ExtensionRuntime(admitFixture: fixture.admit)
        #expect(
            (runtime.execute(fixture.input(operation: "start")) as? NSDictionary)?["ok"] as? Bool
                == false)
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
    }
}
