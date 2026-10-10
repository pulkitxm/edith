import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
@testable import PluginsExtension

@Suite struct PluginsFixtureAdmissionTests {
    private final class MemoryDefaults: UserDefaults {
        override func object(forKey key: String) -> Any? { nil }
        override func string(forKey key: String) -> String? { nil }
        override func dictionary(forKey key: String) -> [String: Any]? { nil }
        override func set(_ value: Any?, forKey key: String) {}
    }

    private struct Input {
        let admission: WorkerFixtureAdmission
        let marker: URL
        let values: [String: Any]
        var context: NSDictionary {
            [
                "operation": "start", "hostIdentifier": values["hostIdentifier"]!,
                "defaultsSuite": (values["hostIdentifier"] as! String) + ".extensions.plugins",
                "dataDirectory": admission.dataDirectory.path,
            ]
        }
        init(_ fixture: EngineFixture) throws {
            admission = try #require(try fixture.admit())
            marker = admission.home.appendingPathComponent("worker-fixture.json")
            values = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: marker))
                    as? [String: Any])
        }
        func admit(_ context: NSDictionary) throws -> WorkerFixtureAdmission? {
            let identifier = values["hostIdentifier"] as! String
            return try WorkerFixtureAdmission.admit(
                extensionID: "plugins", context: context,
                environment: [
                    "EDITH_EXTENSION_FIXTURE_HOME": admission.home.path,
                    "EDITH_EXTENSION_DATA_ROOT": admission.dataDirectory.path,
                    "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": "plugins",
                    "EDITH_SHARED_DEFAULTS_SUITE": identifier + ".extensions.plugins",
                ],
                hostIdentifier: identifier,
                hostBundle: admission.home.deletingLastPathComponent().appendingPathComponent(
                    "Fixture.app"),
                roleDirectory: URL(fileURLWithPath: values["roleDirectory"] as! String),
                roleIdentifier: "com.pulkit.edith.extensions.plugins.app",
                version: "1.0.0", hostABI: "edith-host-2")
        }
    }

    @MainActor @Test func strictMarkerConstructsOnlyOwnedUnavailableToolsAndRealInertModel()
        async throws
    {
        let fixture = try EngineFixture(owner: "plugins")
        defer { fixture.remove() }
        let input = try Input(fixture)
        let tools = try PluginsFixtureTools(admission: input.admission)
        #expect(tools.toolbin.path.hasPrefix(input.admission.home.path + "/"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tools.toolbin.path).isEmpty)
        #expect(!tools.agentMarkerExists("/external-fixture-path", exists: { _ in
            Issue.record("Fixture discovery escaped the owned home"); return true
        }))
        #expect(tools.agentMarkerExists(tools.toolbin.path))
        #expect(tools.executable(named: "npx") == nil)
        #expect(tools.executable(named: "node") == nil)
        #expect(tools.executable(named: "ffmpeg") == nil)
        let defaults = try #require(MemoryDefaults(suiteName: UUID().uuidString))
        let model = tools.makeModel(defaults: defaults)
        await model.discoverAgents()
        #expect(!model.installerAvailable)
        #expect(model.agents.isEmpty)
        await #expect(throws: (any Error).self) {
            try await model.ownedInstaller.install(
                skill: EdithSkillLibrary.skills[0],
                agentIDs: ["amp"], home: input.admission.home, environment: [:])
        }
        await #expect(throws: (any Error).self) {
            try await model.documents.load(EdithSkillLibrary.skills[0])
        }
        await model.shutdown()
        let runtime = ExtensionRuntime(
            admitFixture: input.admit, fixtureDefaults: { _ in defaults })
        #expect((runtime.execute(input.context) as? NSDictionary)?["ok"] as? Bool == true)
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool == true
        )
        _ = runtime.execute(["operation": "stopUI"])
        let snapshotPayload = try SurfaceSnapshotRequest(
            target: .home, tile: SurfaceTile(.ability("plugins"))
        ).encoded(providerID: "plugins")
        let snapshot: (NSData?, NSString?) = await withCheckedContinuation { continuation in
            runtime.invoke(
                [
                    "token": UUID().uuidString, "command": "surface.snapshot",
                    "payload": snapshotPayload,
                ],
                completion: { continuation.resume(returning: ($0, $1)) })
        }
        #expect(snapshot.0 != nil)
        #expect(snapshot.1 == nil)
        let blocked: (NSData?, NSString?) = await withCheckedContinuation { continuation in
            runtime.invoke(
                ["token": UUID().uuidString, "command": "plugins.cli", "payload": Data()],
                completion: { continuation.resume(returning: ($0, $1)) })
        }
        #expect(blocked.0 == nil)
        #expect(blocked.1 != nil)
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        _ = runtime.execute(["operation": "stop"])
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
    }

    @MainActor
    @Test(arguments: ["schema", "foreign-host", "foreign-role", "stale-version", "public-marker"])
    func invalidMarkerFailsBeforeToolbinDefaultsOrModelConstruction(mode: String) throws {
        let fixture = try EngineFixture(owner: "plugins")
        defer { fixture.remove() }
        let input = try Input(fixture)
        var values = input.values
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
        let runtime = ExtensionRuntime(
            admitFixture: input.admit,
            fixtureDefaults: { _ in
                Issue.record("Invalid admission reached defaults construction"); return nil
            })
        #expect((runtime.execute(input.context) as? NSDictionary)?["ok"] as? Bool == false)
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
        #expect(
            !FileManager.default.fileExists(
                atPath: input.admission.home.appendingPathComponent("toolbin").path))
    }

    @Test func toolbinRejectsNonemptyPublicAndAliasedDirectories() throws {
        let fixture = try EngineFixture(owner: "plugins")
        defer { fixture.remove() }
        let admission = try #require(try fixture.admit())
        let tools = try PluginsFixtureTools(admission: admission)
        let unexpected = tools.toolbin.appendingPathComponent("unexpected-tool")
        try Data("synthetic unit version".utf8).write(to: unexpected)
        #expect(throws: (any Error).self) { try PluginsFixtureTools(admission: admission) }
        try FileManager.default.removeItem(at: unexpected)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tools.toolbin.path)
        #expect(throws: (any Error).self) { try PluginsFixtureTools(admission: admission) }
        try FileManager.default.removeItem(at: tools.toolbin)
        try FileManager.default.createSymbolicLink(
            at: tools.toolbin, withDestinationURL: admission.dataDirectory)
        #expect(throws: (any Error).self) { try PluginsFixtureTools(admission: admission) }
    }
}
