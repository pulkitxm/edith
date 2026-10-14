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
        @MainActor
        func admit(_ context: NSDictionary) throws -> WorkerFixtureEngineAdmission? {
            try WorkerFixtureEngineAdmission.current(
                extensionID: "plugins", context: context,
                roleBundle: Bundle(for: ExtensionRuntime.self))
        }

    }

    @MainActor private func makeRuntime(
        _ input: Input, defaults: @escaping (String) -> UserDefaults?
    ) -> ExtensionRuntime {
        #if EDITH_FUNCTIONAL_FIXTURE
        return ExtensionRuntime(admitFixture: input.admit, fixtureDefaults: defaults)
        #else
        return ExtensionRuntime(admitOrdinaryContext: { context in
            guard try input.admit(context) == nil else { throw WorkerFixtureError.invalid }
            return nil
        })
        #endif
    }

    @MainActor @Test func originalRuntimeRejectsFunctionalContextBeforeModelConstruction() async {
        for operation in ["start", "configureUI"] {
            let runtime = ExtensionRuntime()
            let reply =
                runtime.execute([
                    "operation": operation, "defaultsSuite": "synthetic-unavailable-suite",
                    "hostedFunctionalFixture": false,
                ]) as? NSDictionary
            #expect(reply?["ok"] as? Bool == false)
            #expect(
                (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                    == false)
            await withCheckedContinuation { continuation in
                runtime.prepareToStop { continuation.resume() }
            }
        }
    }

    @Test func signedAgentBytesAdmitOnlyMaintainedUniqueIdentifiers() throws {
        let agents = try PluginsFixtureTools.admittedAgents(
            Data("{\"agentIDs\":[\"cursor\",\"amp\"]}".utf8))
        #expect(Set(agents.map(\.id)) == ["amp", "cursor"])
        for payload in [
            "{}", "{\"agentIDs\":[]}", "{\"agentIDs\":[\"unknown\"]}",
            "{\"agentIDs\":[\"amp\",\"amp\"]}", "{\"agentIDs\":[1]}",
            "{\"agentIDs\":[\"amp\"],\"path\":\"/external\"}",
            "{\"agentIDs\":[\"amp\"],\"agentIDs\":[\"cursor\"]}",
            "{\"agentIDs\":[\"amp\"],\"agent\\u0049Ds\":[\"cursor\"]}",
        ] {
            #expect(throws: (any Error).self) {
                try PluginsFixtureTools.admittedAgents(Data(payload.utf8))
            }
        }
    }

    @MainActor @Test func admittedOriginalControlsPersistWithoutDiscoveryOrInstallation()
        async throws
    {
        let suite =
            "com.pulkit.edith.tests.worker-" + UUID().uuidString + ".extension.plugins.worker"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let agents = try PluginsFixtureTools.admittedAgents(Data("{\"agentIDs\":[\"amp\"]}".utf8))
        func makeModel() -> SkillsModel {
            PluginsFixtureTools.makeAdmittedModel(
                defaults: defaults, dataDirectory: data, agents: agents)
        }
        func action(_ value: PluginsUIAction, model: SkillsModel) async throws -> PluginsUISnapshot
        {
            try JSONDecoder().decode(
                PluginsUISnapshot.self,
                from: await PluginsUIBridge.execute(
                    "plugins.ui.action", payload: JSONEncoder().encode(value), model: model))
        }
        let model = makeModel()
        let discovered = try await action(.init(action: "discover"), model: model)
        #expect(discovered.agents.map(\.id) == ["amp"] && !discovered.installerAvailable)
        let skill = EdithSkillLibrary.skills[0]
        let presented = try await action(.init(action: "present", skillID: skill.id), model: model)
        #expect(presented.selectedAgentIDs == ["amp"] && presented.savedAgentSelections == nil)
        let selected = try await action(
            .init(action: "select", agentID: "amp", enabled: false), model: model)
        #expect(
            selected.selectedAgentIDs.isEmpty && selected.savedAgentSelections == ["amp": false])
        #expect(
            defaults.dictionary(forKey: "plugins.agentSelections") as? [String: Bool] == [
                "amp": false
            ])
        await model.shutdown()
        let recreated = makeModel()
        _ = try await action(.init(action: "discover"), model: recreated)
        let restored = try await action(
            .init(action: "present", skillID: skill.id), model: recreated)
        #expect(
            restored.selectedAgentIDs.isEmpty && restored.savedAgentSelections == ["amp": false])
        await recreated.shutdown()
        #expect(!FileManager.default.fileExists(atPath: data.path))
    }

    @MainActor @Test func savedSelectionsDistinguishAbsentEmptyAndRejectNonBooleanStorage() throws {
        let suite =
            "com.pulkit.edith.tests.worker-" + UUID().uuidString + ".extension.plugins.worker"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PluginsFixtureTools.makeAdmittedModel(
            defaults: defaults, dataDirectory: FileManager.default.temporaryDirectory,
            agents: [])
        #expect(try model.savedAgentSelections() == nil)
        defaults.set([String: Bool](), forKey: "plugins.agentSelections")
        #expect(try model.savedAgentSelections() == [:])
        defaults.set(["amp": false], forKey: "plugins.agentSelections")
        #expect(try model.savedAgentSelections() == ["amp": false])
        defaults.set(["amp": 1], forKey: "plugins.agentSelections")
        #expect(throws: (any Error).self) { try model.savedAgentSelections() }
        defaults.set("invalid", forKey: "plugins.agentSelections")
        #expect(throws: (any Error).self) { try model.savedAgentSelections() }
        model.stop()
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
        #expect(
            !tools.agentMarkerExists(
                "/external-fixture-path",
                exists: { _ in
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
        let runtime = makeRuntime(input, defaults: { _ in defaults })
        #expect((runtime.execute(input.context) as? NSDictionary)?["ok"] as? Bool == false)
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false
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
        #expect(snapshot.0 == nil)
        #expect(snapshot.1 != nil)
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
        let runtime = makeRuntime(
            input,
            defaults: { _ in
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

    @MainActor @Test func unsignedMarkerCannotPerformOriginalSelectionActions() async throws {
        let fixture = try EngineFixture(owner: "plugins")
        defer { fixture.remove() }
        let input = try Input(fixture)
        let runtime = makeRuntime(
            input,
            defaults: { _ in
                Issue.record("Unsigned marker reached preferences construction")
                return nil
            })
        #expect((runtime.execute(input.context) as? NSDictionary)?["ok"] as? Bool == false)
        for payload in [
            "{\"action\":\"discover\"}",
            "{\"action\":\"select\",\"agentID\":\"amp\",\"enabled\":false}",
        ] {
            let reply: (NSData?, NSString?) = await withCheckedContinuation { continuation in
                runtime.invoke([
                    "token": UUID().uuidString, "command": "plugins.ui.action",
                    "payload": Data(payload.utf8),
                ]) { continuation.resume(returning: ($0, $1)) }
            }
            #expect(reply.0 == nil && reply.1 != nil)
        }
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
    }
}
