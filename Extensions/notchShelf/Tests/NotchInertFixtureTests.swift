import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchInertFixtureTests {
    @Test func constructorAndMetadataRemainDetachedBeforeAdmission() async throws {
        let probe = InertConstructionProbe()
        let runtime = probe.runtime { _ in
            probe.admissions += 1
            return nil
        }
        let status = try state(runtime)
        #expect(status["startRequested"] as? Bool == false)
        #expect(status["running"] as? Bool == false)
        #expect(status["controllerAttached"] as? Bool == false)
        #expect(status["panelAttached"] as? Bool == false)
        #expect(status["fixture"] as? Bool == false)
        let metadata = try #require(runtime.execute(["operation": "describe"]) as? NSDictionary)
        #expect(metadata["id"] as? String == "notchShelf")
        #expect(metadata["role"] as? String == "helper")
        #expect(metadata["version"] is String)
        #expect(metadata["hostABI"] is String)
        let reply = await invoke(runtime, "notch.panel.attach")
        #expect(reply.data == nil)
        #expect(reply.error != nil)
        await stop(runtime)
        #expect(probe.admissions == 0)
        #expect(probe.dependencies == 0)
    }

    @Test func exactOwnedHelperStartsAndStopsWithoutAnyDependencies() async throws {
        let fixture = try InertNotchFixture()
        defer { fixture.remove() }
        let probe = InertConstructionProbe()
        let runtime = probe.runtime { input in
            probe.admissions += 1
            return try fixture.admit(input)
        }
        #expect(ok(runtime.execute(fixture.start)))
        #expect(ok(runtime.execute(fixture.start)))
        let status = try state(runtime)
        #expect(status["startRequested"] as? Bool == true)
        #expect(status["running"] as? Bool == false)
        #expect(status["fixture"] as? Bool == true)
        #expect(status["fixtureRejected"] as? Bool == false)
        #expect(status["controllerAttached"] as? Bool == false)
        #expect(status["panelAttached"] as? Bool == false)
        #expect(status["stopped"] as? Bool == false)
        for operation in ["configureUI", "view", "synchronize"] {
            #expect(!ok(runtime.execute(["operation": operation])))
        }
        #expect(ok(runtime.execute(["operation": "stopUI"])))
        #expect(ok(runtime.execute(["operation": "cancelCommand", "token": "missing"])))
        #expect(ok(runtime.execute(["operation": "stop"])))
        await stop(runtime)
        await stop(runtime)
        let stopped = try state(runtime)
        #expect(stopped["startRequested"] as? Bool == false)
        #expect(stopped["running"] as? Bool == false)
        #expect(stopped["controllerAttached"] as? Bool == false)
        #expect(stopped["panelAttached"] as? Bool == false)
        #expect(stopped["stopped"] as? Bool == true)
        #expect(!ok(runtime.execute(fixture.start)))
        let reply = await invoke(runtime, "notchShelf.cli.catalog")
        #expect(reply.data == nil)
        #expect(reply.error != nil)
        #expect(probe.admissions == 2)
        #expect(probe.dependencies == 0)
    }

    @Test(arguments: [
        "notch.panel.attach", "notch.panel.detach", "notch.panel.scene.stop", "notch.panel.wait",
        "notch.panel.geometry", "notch.panel.measure", "notch.panel.pointer",
        "notch.panel.transfer.ack", "notch.panel.transfer.finish", "notch.panel.drop",
        "notch.panel.promise.prepare", "notch.panel.promise.finish", "notch.chrome.read",
        "notch.chrome.action", "notch.chrome.thumbnail", "notch.chrome.browser",
        "notch.chrome.quick", "notch.chrome.camera", "browser.cli", "browser.cli.start",
        "browser.cli.read", "browser.cli.cancel", "browser.cli.end", "notch.cli",
        "notch.cli.start", "notch.cli.read", "notch.cli.cancel", "notch.cli.end",
        "surface.snapshot", "surface.perform", "notch.settings.read", "notch.settings.update",
        "unknown.operation",
    ])
    func admittedFixtureRejectsEveryEffectfulOperationBeforeConstruction(_ operation: String)
        async throws
    {
        let fixture = try InertNotchFixture()
        defer { fixture.remove() }
        let probe = InertConstructionProbe()
        let runtime = probe.runtime { try fixture.admit($0) }
        #expect(ok(runtime.execute(fixture.start)))
        let reply = await invoke(runtime, operation)
        #expect(reply.data == nil)
        #expect(reply.error == ExtensionPeerError.unavailable.localizedDescription)
        #expect(probe.dependencies == 0)
        #expect(try state(runtime)["controllerAttached"] as? Bool == false)
        await stop(runtime)
        #expect(probe.dependencies == 0)
    }

    @Test func catalogUsesOriginalStaticParsersAndRejectsUnboundedInputs() async throws {
        let fixture = try InertNotchFixture()
        defer { fixture.remove() }
        let probe = InertConstructionProbe()
        let runtime = probe.runtime { try fixture.admit($0) }
        #expect(ok(runtime.execute(fixture.start)))
        let reply = await invoke(runtime, "notchShelf.cli.catalog")
        #expect(reply.error == nil)
        let data = try #require(reply.data)
        #expect(data.count < 262_144)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["owner"] as? String == "notchShelf")
        #expect(catalog["version"] as? Int == 1)
        let commands = try #require(catalog["commands"] as? [[String: Any]])
        #expect(!commands.isEmpty && commands.count <= 128)
        #expect(
            Set(commands.compactMap { $0["operation"] as? String }) == [
                "notch.cli", "browser.cli",
            ])
        #expect(commands.contains { $0["route"] as? [String] == ["browser", "navigate"] })
        #expect(commands.contains { $0["route"] as? [String] == ["shelf", "ls"] })
        for payload in [Data("{\"activate\":true}".utf8), Data(repeating: 32, count: 262_144)] {
            let rejected = await invoke(runtime, "notchShelf.cli.catalog", payload: payload)
            #expect(rejected.data == nil)
            #expect(rejected.error != nil)
        }
        await stop(runtime)
        #expect(probe.dependencies == 0)
    }

    @Test func invalidFixtureIntentFailsClosedAndCannotRetryAsProduction() async throws {
        let fixture = try InertNotchFixture()
        defer { fixture.remove() }
        try Data("{}".utf8).write(to: fixture.marker)
        let probe = InertConstructionProbe()
        let runtime = probe.runtime { input in
            probe.admissions += 1
            return try fixture.admit(input)
        }
        #expect(!ok(runtime.execute(fixture.start)))
        #expect(try state(runtime)["fixtureRejected"] as? Bool == true)
        #expect(try state(runtime)["startRequested"] as? Bool == false)
        #expect(!ok(runtime.execute(["operation": "start", "defaultsSuite": "production"])))
        for command in ["notchShelf.cli.catalog", "notch.panel.attach", "surface.snapshot"] {
            let rejected = await invoke(runtime, command)
            #expect(rejected.data == nil)
            #expect(rejected.error != nil)
        }
        #expect(!ok(runtime.execute(["operation": "configureUI"])))
        await stop(runtime)
        #expect(probe.admissions == 1)
        #expect(probe.dependencies == 0)
    }

    @Test func currentAdmissionRejectsTestIntentBeforeContextResolution() async throws {
        let probe = InertConstructionProbe()
        let runtime = ExtensionRuntime(contextSource: {
            probe.dependencies += 1
            return nil
        })
        #expect(
            !ok(
                runtime.execute([
                    "operation": "start", "hostIdentifier": "com.pulkit.edith.tests.invalid",
                ])))
        #expect(try state(runtime)["fixtureRejected"] as? Bool == true)
        #expect(probe.dependencies == 0)
        await stop(runtime)
        #expect(probe.dependencies == 0)
    }

    @Test func admissionIsBoundToOwnRoleAndSameFixtureForRepeatedStart() async throws {
        let fixture = try InertNotchFixture()
        let second = try InertNotchFixture()
        let foreign = try InertNotchFixture(owner: "colorPicker")
        defer {
            fixture.remove(); second.remove(); foreign.remove()
        }
        let probe = InertConstructionProbe()
        var selected = fixture
        let runtime = probe.runtime { input in try selected.admit(input) }
        #expect(ok(runtime.execute(fixture.start)))
        selected = second
        #expect(!ok(runtime.execute(second.start)))
        #expect(try state(runtime)["fixtureRejected"] as? Bool == true)
        #expect(try state(runtime)["startRequested"] as? Bool == false)
        let foreignRuntime = probe.runtime { try foreign.admit($0) }
        #expect(!ok(foreignRuntime.execute(foreign.start)))
        #expect(try state(foreignRuntime)["fixtureRejected"] as? Bool == true)
        await stop(runtime)
        await stop(foreignRuntime)
        #expect(probe.dependencies == 0)
    }

    private func state(_ runtime: ExtensionRuntime) throws -> NSDictionary {
        try #require(runtime.execute(["operation": "status"]) as? NSDictionary)
    }

    private func ok(_ reply: NSObject) -> Bool {
        (reply as? NSDictionary)?["ok"] as? Bool == true
    }

    private func stop(_ runtime: ExtensionRuntime) async {
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
    }

    private func invoke(
        _ runtime: ExtensionRuntime, _ command: String, payload: Data = Data("{}".utf8)
    ) async -> (data: Data?, error: String?) {
        await withCheckedContinuation { continuation in
            runtime.invoke(["token": UUID().uuidString, "command": command, "payload": payload]) {
                data, error in
                continuation.resume(returning: (data as Data?, error as String?))
            }
        }
    }
}

@MainActor private final class InertConstructionProbe {
    var admissions = 0
    var dependencies = 0

    func runtime(
        _ admission: @escaping @MainActor (NSDictionary) throws -> WorkerFixtureAdmission?
    ) -> ExtensionRuntime {
        ExtensionRuntime(
            fixtureAdmission: admission,
            contextSource: {
                self.dependencies += 1
                return nil
            },
            connectedDisplays: {
                self.dependencies += 1
                return [:]
            },
            createController: { _, _ in
                self.dependencies += 1
                preconditionFailure("Inert Runtime constructed a controller")
            })
    }
}

private struct InertNotchFixture {
    let root: URL
    let home: URL
    let data: URL
    let role: URL
    let owner: String
    let identifier = "com.pulkit.edith.tests.worker-" + UUID().uuidString
    var marker: URL { home.appendingPathComponent("worker-fixture.json") }
    var start: NSDictionary {
        [
            "operation": "start", "hostIdentifier": identifier,
            "defaultsSuite": identifier + ".extensions." + owner, "dataDirectory": data.path,
        ]
    }

    init(owner: String = "notchShelf") throws {
        self.owner = owner
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("notch-inert-" + UUID().uuidString)
        home = root.appendingPathComponent(owner + "-home")
        data = root.appendingPathComponent("Data/" + owner)
        role = root.appendingPathComponent(
            "Extensions/" + owner + "/edith-host-2/arm64/1.0.0/" + owner
                + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/"
                + owner + "/helper.bundle")
        for directory in [root, home, data, role, root.appendingPathComponent("Fixture.app")] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try JSONSerialization.data(withJSONObject: [
            "schema": 1, "hostIdentifier": identifier, "extensionID": owner,
            "dataDirectory": data.path, "roleDirectory": role.path,
            "version": "1.0.0", "hostABI": "edith-host-2",
        ]).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    func admit(_ input: NSDictionary) throws -> WorkerFixtureAdmission? {
        try WorkerFixtureAdmission.admit(
            extensionID: owner, context: input,
            environment: [
                "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": owner,
                "EDITH_SHARED_DEFAULTS_SUITE": identifier + ".extensions." + owner,
                "EDITH_EXTENSION_FIXTURE_HOME": home.path,
                "EDITH_EXTENSION_DATA_ROOT": data.path,
            ], hostIdentifier: identifier, hostBundle: root.appendingPathComponent("Fixture.app"),
            roleDirectory: role, roleIdentifier: "com.pulkit.edith.extensions." + owner + ".helper",
            version: "1.0.0", hostABI: "edith-host-2")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
