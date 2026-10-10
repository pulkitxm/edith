import Foundation
import Testing
@testable import WorkerFixtureSupport

@Suite struct WorkerFixtureAdmissionTests {
    @Test(arguments: [
        "focusDim", "micMute", "systemStats", "windowSweaters", "colorPicker", "emoji", "presenter",
        "keystrokeHighlight", "music",
    ])
    func admitsBoundOwnedFixture(_ owner: String) throws {
        let fixture = try Fixture(owner: owner)
        defer { fixture.remove() }
        let admission = try #require(try fixture.admit())
        #expect(admission.extensionID == owner)
        #expect(admission.role == (owner == "music" ? .app : .helper))
        #expect(admission.home.path == fixture.home.path)
        #expect(admission.dataDirectory.path == fixture.data.path)
    }

    @Test(arguments: [
        "music", "focusDim", "micMute", "systemStats", "windowSweaters", "colorPicker", "emoji",
        "presenter", "keystrokeHighlight",
    ])
    func rejectsWrongRole(_ owner: String) throws {
        let fixture = try Fixture(owner: owner); defer { fixture.remove() }
        let wrong = "com.pulkit.edith.extensions." + owner + (owner == "music" ? ".helper" : ".app")
        #expect(throws: (any Error).self) { try fixture.admit(roleIdentifierOverride: wrong) }
    }

    @Test func productionHasNoFixture() throws {
        #expect(
            try WorkerFixtureAdmission.admit(
                extensionID: "micMute", context: [:], environment: [:],
                hostIdentifier: "com.pulkit.edith",
                hostBundle: URL(fileURLWithPath: "/Applications/Edith.app"),
                roleDirectory: URL(fileURLWithPath: "/Applications/helper.bundle"),
                roleIdentifier: nil, version: nil, hostABI: nil) == nil)
    }

    @Test(arguments: [
        "owner", "namespace", "suite", "data", "version", "extra", "schema", "missing", "large",
        "homeMode", "markerMode", "symlink",
    ])
    func rejectsUnboundFixture(_ change: String) throws {
        var fixture = try Fixture(owner: "micMute")
        defer { fixture.remove() }
        switch change {
        case "owner": fixture.environment["EDITH_EXTENSION_ID"] = "emoji"
        case "namespace": fixture.identifier = "com.pulkit.edith.tests.worker-invalid"
        case "suite": fixture.context["defaultsSuite"] = "com.pulkit.edith"
        case "data": fixture.context["dataDirectory"] = "/tmp/foreign"
        case "version": fixture.marker["version"] = "1.1.0"; try fixture.writeMarker()
        case "extra": fixture.marker["extra"] = true; try fixture.writeMarker()
        case "schema": fixture.marker["schema"] = true; try fixture.writeMarker()
        case "missing": try FileManager.default.removeItem(at: fixture.markerURL)
        case "large": try Data(repeating: 65, count: 16_385).write(to: fixture.markerURL)
        case "homeMode":
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fixture.home.path)
        case "markerMode":
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: fixture.markerURL.path)
        case "symlink":
            let moved = fixture.root.appendingPathComponent("moved.json")
            try FileManager.default.moveItem(at: fixture.markerURL, to: moved)
            try FileManager.default.createSymbolicLink(
                at: fixture.markerURL, withDestinationURL: moved)
        default: Issue.record("Unknown fixture mutation")
        }
        #expect(throws: (any Error).self) { try fixture.admit() }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let data: URL
        let role: URL
        let owner: String
        var identifier: String
        var context: [String: Any]
        var environment: [String: String]
        var marker: [String: Any]
        var markerURL: URL { home.appendingPathComponent("worker-fixture.json") }

        init(owner: String) throws {
            self.owner = owner
            identifier = "com.pulkit.edith.tests.worker-" + UUID().uuidString
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("worker-fixture-" + UUID().uuidString)
            home = root.appendingPathComponent(owner + "-home")
            data = root.appendingPathComponent("support/Data/" + owner)
            role = root.appendingPathComponent(
                "support/Extensions/" + owner + "/edith-host-2/arm64/1.0.0/" + owner
                    + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/"
                    + owner + "/" + (owner == "music" ? "app" : "helper") + ".bundle")
            for directory in [home, data, role, root.appendingPathComponent("Fixture.app")] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            context = [
                "hostIdentifier": identifier, "defaultsSuite": identifier + ".extensions." + owner,
                "dataDirectory": data.path,
            ]
            environment = [
                "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": owner,
                "EDITH_SHARED_DEFAULTS_SUITE": identifier + ".extensions." + owner,
                "EDITH_EXTENSION_FIXTURE_HOME": home.path, "EDITH_EXTENSION_DATA_ROOT": data.path,
            ]
            marker = [
                "schema": 1, "hostIdentifier": identifier, "extensionID": owner,
                "dataDirectory": data.path, "roleDirectory": role.path, "version": "1.0.0",
                "hostABI": "edith-host-2",
            ]
            try writeMarker()
        }

        func writeMarker() throws {
            try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        }

        func admit(roleIdentifierOverride: String? = nil) throws -> WorkerFixtureAdmission? {
            try WorkerFixtureAdmission.admit(
                extensionID: owner, context: context as NSDictionary, environment: environment,
                hostIdentifier: identifier, hostBundle: root.appendingPathComponent("Fixture.app"),
                roleDirectory: role,
                roleIdentifier: roleIdentifierOverride ?? "com.pulkit.edith.extensions." + owner
                    + "." + (owner == "music" ? "app" : "helper"),
                version: "1.0.0", hostABI: "edith-host-2")
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
