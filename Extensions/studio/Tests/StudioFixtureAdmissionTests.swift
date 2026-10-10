import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
import EdithStudio
@testable import StudioExtension

@Suite struct StudioFixtureAdmissionTests {
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
                "defaultsSuite": (values["hostIdentifier"] as! String) + ".extensions.studio",
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
                extensionID: "studio", context: context,
                environment: [
                    "EDITH_EXTENSION_FIXTURE_HOME": admission.home.path,
                    "EDITH_EXTENSION_DATA_ROOT": admission.dataDirectory.path,
                    "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": "studio",
                    "EDITH_SHARED_DEFAULTS_SUITE": identifier + ".extensions.studio",
                ],
                hostIdentifier: identifier,
                hostBundle: admission.home.deletingLastPathComponent().appendingPathComponent(
                    "Fixture.app"),
                roleDirectory: URL(fileURLWithPath: values["roleDirectory"] as! String),
                roleIdentifier: "com.pulkit.edith.extensions.studio.app",
                version: "1.0.0", hostABI: "edith-host-2")
        }
    }

    @MainActor @Test func strictMarkerConstructsOnlyOwnedUnavailableToolsAndRealInertModel()
        async throws
    {
        let fixture = try EngineFixture(owner: "studio")
        defer { fixture.remove() }
        let input = try Input(fixture)
        let tools = try StudioFixtureTools(admission: input.admission)
        #expect(tools.toolbin.path.hasPrefix(input.admission.home.path + "/"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tools.toolbin.path).isEmpty)
        #expect(tools.executable(named: "npx") == nil)
        #expect(tools.executable(named: "node") == nil)
        #expect(tools.executable(named: "ffmpeg") == nil)
        let defaults = try #require(MemoryDefaults(suiteName: UUID().uuidString))
        let model = tools.makeModel(defaults: defaults)
        model.start()
        for _ in 0..<10_000 {
            if model.environment.temporaryRoot == tools.detect().temporaryRoot { break }
            await Task.yield()
        }
        #expect(model.environment.ffmpeg == nil)
        #expect(model.environment.ffprobe == nil)
        #expect(model.environment.qpdf == nil)
        #expect(!model.environment.appleIntelligenceAvailable)
        #expect(!model.environment.satisfies(.translation))
        model.install(.ffmpeg)
        for _ in 0..<10_000 {
            if model.installing == nil { break }
            await Task.yield()
        }
        #expect(model.notice == nil)
        #expect(model.message == "Installation is unavailable in the worker fixture.")
        await model.stopAndWait()
        let runtime = ExtensionRuntime(
            uiConfiguration: { _ in nil }, admitFixture: input.admit,
            fixtureDefaults: { _ in defaults })
        #expect((runtime.execute(input.context) as? NSDictionary)?["ok"] as? Bool == true)
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool == true
        )
        let blocked: (NSData?, NSString?) = await withCheckedContinuation { continuation in
            runtime.invoke(
                ["token": UUID().uuidString, "command": "studio.cli", "payload": Data()],
                completion: { continuation.resume(returning: ($0, $1)) })
        }
        #expect(blocked.0 == nil)
        #expect(blocked.1 != nil)
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
    }

    @MainActor
    @Test(arguments: ["schema", "foreign-host", "foreign-role", "stale-version", "public-marker"])
    func invalidMarkerFailsBeforeToolbinDefaultsOrModelConstruction(mode: String) throws {
        let fixture = try EngineFixture(owner: "studio")
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
            uiConfiguration: { _ in nil }, admitFixture: input.admit,
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
        let fixture = try EngineFixture(owner: "studio")
        defer { fixture.remove() }
        let admission = try #require(try fixture.admit())
        let tools = try StudioFixtureTools(admission: admission)
        let unexpected = tools.toolbin.appendingPathComponent("unexpected-tool")
        try Data("synthetic unit version".utf8).write(to: unexpected)
        #expect(throws: (any Error).self) { try StudioFixtureTools(admission: admission) }
        try FileManager.default.removeItem(at: unexpected)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tools.toolbin.path)
        #expect(throws: (any Error).self) { try StudioFixtureTools(admission: admission) }
        try FileManager.default.removeItem(at: tools.toolbin)
        try FileManager.default.createSymbolicLink(
            at: tools.toolbin, withDestinationURL: admission.dataDirectory)
        #expect(throws: (any Error).self) { try StudioFixtureTools(admission: admission) }
    }
}
