import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport

@testable import KeepAwakeExtension

@Suite @MainActor struct KeepAwakeRuntimeFixtureTests {
    private final class MemoryDefaults: UserDefaults {
        private var values: [String: Any] = [:]
        override func object(forKey key: String) -> Any? { values[key] }
        override func string(forKey key: String) -> String? { values[key] as? String }
        override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        override func dictionaryRepresentation() -> [String: Any] { values }
        override func set(_ value: Any?, forKey key: String) { values[key] = value }
        override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    }

    private struct Input {
        let admission: WorkerFixtureAdmission
        let values: [String: Any]
        var marker: URL { admission.home.appendingPathComponent("worker-fixture.json") }
        var context: NSDictionary {
            [
                "operation": "start", "hostIdentifier": values["hostIdentifier"]!,
                "defaultsSuite": (values["hostIdentifier"] as! String) + ".extensions.keepAwake",
                "dataDirectory": admission.dataDirectory.path,
            ]
        }
        init(_ fixture: EngineFixture) throws {
            admission = try #require(try fixture.admit())
            values = try #require(
                try JSONSerialization.jsonObject(
                    with: Data(
                        contentsOf: admission.home.appendingPathComponent("worker-fixture.json")))
                    as? [String: Any])
        }
        func admit(_ context: NSDictionary) throws -> WorkerFixtureAdmission? {
            let identifier = values["hostIdentifier"] as! String
            return try WorkerFixtureAdmission.admit(
                extensionID: "keepAwake", context: context,
                environment: [
                    "EDITH_EXTENSION_FIXTURE_HOME": admission.home.path,
                    "EDITH_EXTENSION_DATA_ROOT": admission.dataDirectory.path,
                    "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": "keepAwake",
                    "EDITH_SHARED_DEFAULTS_SUITE": identifier + ".extensions.keepAwake",
                ],
                hostIdentifier: identifier,
                hostBundle: admission.home.deletingLastPathComponent().appendingPathComponent(
                    "Fixture.app"),
                roleDirectory: URL(fileURLWithPath: values["roleDirectory"] as! String),
                roleIdentifier: "com.pulkit.edith.extensions.keepAwake.helper",
                version: "1.0.0", hostABI: "edith-host-2")
        }
    }

    private func invoke(_ runtime: KeepAwakeRuntime, command: String, payload: Data) async throws
        -> Data
    {
        try await withCheckedThrowingContinuation { continuation in
            runtime.invoke(
                ["token": UUID().uuidString, "command": command, "payload": payload]
            ) { data, error in
                if let error {
                    continuation.resume(throwing: NSError(domain: error as String, code: 1))
                } else if let data {
                    continuation.resume(returning: data as Data)
                } else {
                    continuation.resume(throwing: ExtensionPeerError.unavailable)
                }
            }
        }
    }

    @Test func checkedFixtureRunsOriginalSurfaceControlsAndDrainsWithoutLiveDependencies()
        async throws
    {
        let fixture = try EngineFixture(owner: "keepAwake")
        defer { fixture.remove() }
        let input = try Input(fixture)
        let defaults = try #require(MemoryDefaults(suiteName: UUID().uuidString))
        var defaultCreations = 0
        var liveCreations = 0
        let runtime = KeepAwakeRuntime(
            admitFixture: input.admit,
            makeDefaults: { _ in
                defaultCreations += 1; return defaults
            },
            makeProductionStore: { values in
                liveCreations += 1
                Issue.record("Admitted fixture reached live Store dependencies")
                return KeepAwakeStore.fixture(defaults: values)
            })
        #expect((runtime.execute(input.context) as? NSDictionary)?["ok"] as? Bool == true)
        #expect(defaultCreations == 1 && liveCreations == 0)
        let request = SurfaceSnapshotRequest(target: .home, tile: .init(.actions))
        let before = try await invoke(
            runtime, command: "surface.snapshot", payload: request.encoded(providerID: "keepAwake"))
        #expect(
            try SurfaceSnapshot.decode(before, providerID: "keepAwake").rows.first?.value == "Off")
        let enable = SurfaceActionRequest(snapshot: request, actionID: "enable")
        let after = try await invoke(
            runtime, command: "surface.perform", payload: enable.encoded(providerID: "keepAwake"))
        #expect(
            try SurfaceSnapshot.decode(after, providerID: "keepAwake").rows.first?.value == "Awake")
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["preventingSleep"] as? Bool
                == true)
        _ = runtime.execute(["operation": "stopUI"])
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool == true
        )
        await #expect(throws: (any Error).self) {
            _ = try await invoke(
                runtime, command: "surface.perform",
                payload: enable.encoded(providerID: "keepAwake"))
        }
        let update = try JSONEncoder().encode(
            ControlPreferenceUpdate(
                values: ControlPresentationContract.encode(["preventSleep": false]), removed: []))
        _ = try await invoke(runtime, command: "keepAwake.ui.update", payload: update)
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["preventingSleep"] as? Bool
                == false)
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
        #expect(defaults.bool(forKey: KeepAwakeKeys.enabled))
        await #expect(throws: (any Error).self) {
            _ = try await invoke(runtime, command: "keepAwake.ui.read", payload: Data("{}".utf8))
        }
    }

    @Test(arguments: [
        "schema", "foreign-host", "foreign-role", "stale-version", "public-marker",
        "missing-marker", "symlink-marker", "foreign-suite", "foreign-data",
    ])
    func invalidIntentFailsBeforeDefaultsAndLiveStore(mode: String) throws {
        let fixture = try EngineFixture(owner: "keepAwake")
        defer { fixture.remove() }
        let input = try Input(fixture)
        var values = input.values
        var context = input.context as! [String: Any]
        if mode == "schema" { values["schema"] = true }
        if mode == "foreign-host" {
            values["hostIdentifier"] = "com.pulkit.edith.tests.worker-" + UUID().uuidString
        }
        if mode == "foreign-role" { values["roleDirectory"] = input.admission.home.path }
        if mode == "stale-version" { values["version"] = "0.9.0" }
        try JSONSerialization.data(withJSONObject: values).write(to: input.marker)
        if mode == "public-marker" {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: input.marker.path)
        }
        if mode == "missing-marker" { try FileManager.default.removeItem(at: input.marker) }
        if mode == "symlink-marker" {
            let original = input.admission.home.appendingPathComponent("original.json")
            try FileManager.default.moveItem(at: input.marker, to: original)
            try FileManager.default.createSymbolicLink(
                at: input.marker, withDestinationURL: original)
        }
        if mode == "foreign-suite" { context["defaultsSuite"] = "com.pulkit.edith.tests.foreign" }
        if mode == "foreign-data" { context["dataDirectory"] = input.admission.home.path }
        var defaultCreations = 0
        let runtime = KeepAwakeRuntime(
            admitFixture: input.admit,
            makeDefaults: { _ in
                defaultCreations += 1; return nil
            },
            makeProductionStore: { values in
                Issue.record("Invalid fixture intent reached live Store dependencies")
                return KeepAwakeStore.fixture(defaults: values)
            })
        #expect(
            (runtime.execute(context as NSDictionary) as? NSDictionary)?["ok"] as? Bool == false)
        #expect(defaultCreations == 0)
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
    }

    @Test func thrownAdmissionNeverFallsThroughToProduction() {
        let runtime = KeepAwakeRuntime(
            admitFixture: { _ in throw WorkerFixtureError.invalid },
            makeDefaults: { _ in
                Issue.record("Rejected admission reached defaults"); return nil
            },
            makeProductionStore: { values in
                Issue.record("Rejected admission reached live Store")
                return KeepAwakeStore.fixture(defaults: values)
            })
        #expect(
            (runtime.execute([
                "operation": "start", "defaultsSuite": "com.pulkit.edith.tests.synthetic",
            ]) as? NSDictionary)?["ok"] as? Bool == false)
    }
}
