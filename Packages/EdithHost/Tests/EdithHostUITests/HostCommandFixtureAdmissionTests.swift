import Foundation
import Testing
import WorkerLifecycleFixtureSupport
@testable import EdithHost

@Suite struct HostCommandFixtureAdmissionTests {
    @Test func issuedCommandFixturePassesTheActualStartupContract() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var appearances = 0
        var starts = 0
        try HostWorkerStartAdmission.perform(
            admit: {
                try fixture.admit()
                return ["helper"]
            },
            appearance: { appearances += 1 },
            start: { _ in starts += 1 })
        #expect(appearances == 1)
        #expect(starts == 1)
        try fixture.issuer.validateExact(
            fixture.selection, hostApp: fixture.app, defaultsSuite: fixture.suite)
    }

    @Test(arguments: [
        "command-identifier", "malformed-identifier", "missing-home", "foreign-home",
        "wrong-owner", "wrong-suite", "missing-marker", "marker-version",
        "marker-extra", "marker-permission", "home-permission", "root-permission",
        "marker-symlink", "marker-hardlink", "wrong-host", "wrong-role",
    ])
    func malformedCommandFixtureRejectsBeforeAppearanceAndStart(_ change: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var identifier = fixture.identifier
        var environment = fixture.environment
        var owner = "keepAwake"
        var suite = fixture.suite
        var app = fixture.app
        var roles = fixture.roles
        switch change {
        case "command-identifier":
            identifier = identifier.replacingOccurrences(of: ".worker-", with: ".command-")
            environment["EDITH_APPLICATION_IDENTIFIER"] = identifier
            suite = identifier + ".extensions.keepAwake"
            environment["EDITH_SHARED_DEFAULTS_SUITE"] = suite
        case "malformed-identifier":
            identifier = "com.pulkit.edith.tests.worker-invalid"
        case "missing-home": environment["EDITH_EXTENSION_FIXTURE_HOME"] = nil
        case "foreign-home":
            environment["EDITH_EXTENSION_FIXTURE_HOME"] =
                fixture.root.appendingPathComponent("foreign-home").path
        case "wrong-owner": owner = "emoji"
        case "wrong-suite": suite = fixture.identifier + ".host"
        case "missing-marker": try FileManager.default.removeItem(at: fixture.marker)
        case "marker-version": try fixture.changeMarker("version", value: "1.1.0")
        case "marker-extra": try fixture.changeMarker("unexpected", value: true)
        case "marker-permission":
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: fixture.marker.path)
        case "home-permission":
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fixture.home.path)
        case "root-permission":
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
        case "marker-symlink", "marker-hardlink":
            let original = fixture.root.appendingPathComponent("original-marker.json")
            try FileManager.default.moveItem(at: fixture.marker, to: original)
            if change == "marker-symlink" {
                try FileManager.default.createSymbolicLink(
                    at: fixture.marker, withDestinationURL: original)
            } else {
                try FileManager.default.linkItem(at: original, to: fixture.marker)
            }
        case "wrong-host": app = fixture.root.appendingPathComponent("Host.app")
        case "wrong-role":
            roles = [
                .init(
                    directory: fixture.selection.roleDirectory,
                    identifier: "com.pulkit.edith.extensions.keepAwake.app",
                    version: "1.0.0", hostABI: "edith-host-2")
            ]
        default: Issue.record("Unknown fixture mutation")
        }
        var appearances = 0
        var starts = 0
        #expect(
            HostWorkerStartAdmission.hasFixtureIntent(
                identifier: identifier, environment: environment))
        #expect(throws: (any Error).self) {
            try HostWorkerStartAdmission.perform(
                admit: {
                    try HostWorkerStartAdmission.admitFixture(
                        identifier: identifier, owner: owner, version: "1.0.0",
                        hostABI: "edith-host-2", supportDirectory: fixture.root,
                        hostBundle: app, dataDirectory: fixture.selection.dataDirectory,
                        defaultsSuite: suite, roles: roles, environment: environment)
                    return ["helper"]
                },
                appearance: { appearances += 1 },
                start: { _ in starts += 1 })
        }
        #expect(appearances == 0)
        #expect(starts == 0)
    }

    private struct Fixture {
        let root: URL
        let identifier: String
        let app: URL
        let home: URL
        let suite: String
        let issuer: WorkerLifecycleFixture
        let selection: WorkerLifecycleFixture.Selection
        let environment: [String: String]

        var marker: URL { home.appendingPathComponent("worker-fixture.json") }
        var roles: [HostWorkerStartAdmission.FixtureRole] {
            [
                .init(
                    directory: selection.roleDirectory,
                    identifier: "com.pulkit.edith.extensions.keepAwake.helper",
                    version: selection.version, hostABI: selection.hostABI)
            ]
        }

        init() throws {
            let manager = FileManager.default
            root = manager.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("command-admission-" + UUID().uuidString)
            identifier = "com.pulkit.edith.tests.worker-" + UUID().uuidString
            app = root.appendingPathComponent("Fixture.app", isDirectory: true)
            suite = identifier + ".extensions.keepAwake"
            let slot = String(identifier.dropFirst("com.pulkit.edith.tests.".count))
            let identity = root.appendingPathComponent("Edith Tests").appendingPathComponent(slot)
            let data = identity.appendingPathComponent("Data/keepAwake")
            let role = identity.appendingPathComponent(
                "Extensions/keepAwake/edith-host-2/arm64/1.0.0/keepAwake/"
                    + "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/"
                    + "Contents/Resources/Payload/keepAwake/helper.bundle")
            for directory in [root, app, data, role] {
                try manager.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            issuer = try WorkerLifecycleFixture(root: root, hostIdentifier: identifier)
            home = try issuer.home(for: "keepAwake")
            selection = .init(
                extensionID: "keepAwake", dataDirectory: data, roleDirectory: role,
                version: "1.0.0", hostABI: "edith-host-2")
            try issuer.issue(selection, hostApp: app, defaultsSuite: suite)
            environment = [
                "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": "keepAwake",
                "EDITH_SHARED_DEFAULTS_SUITE": suite, "EDITH_EXTENSION_DATA_ROOT": data.path,
                "EDITH_EXTENSION_FIXTURE_HOME": home.path,
            ]
        }

        func admit() throws {
            try HostWorkerStartAdmission.admitFixture(
                identifier: identifier, owner: "keepAwake", version: selection.version,
                hostABI: selection.hostABI, supportDirectory: root, hostBundle: app,
                dataDirectory: selection.dataDirectory, defaultsSuite: suite,
                roles: roles, environment: environment)
        }

        func changeMarker(_ key: String, value: Any) throws {
            var values =
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: marker)) as! [String: Any]
            values[key] = value
            try JSONSerialization.data(withJSONObject: values).write(to: marker)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
