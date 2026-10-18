import Darwin
import Foundation
import WorkerFixtureSupport

public struct EngineFixture {
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

    public init(owner: String) throws {
        self.owner = owner
        identifier = "com.pulkit.edith.tests.worker-" + UUID().uuidString
        guard let temporaryPath = ProcessInfo.processInfo.environment["TMPDIR"],
            temporaryPath.hasPrefix("/")
        else { throw WorkerFixtureError.invalid }
        let temporary = URL(fileURLWithPath: temporaryPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard temporary.path == temporary.standardizedFileURL.path,
            temporary.path == temporary.resolvingSymlinksInPath().path
        else { throw WorkerFixtureError.invalid }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
            attributes[.ownerAccountID] as? UInt32 == getuid(),
            attributes[.posixPermissions] as? Int == 0o700
        else { throw WorkerFixtureError.invalid }
        root = temporary.appendingPathComponent("worker-fixture-" + UUID().uuidString)
        home = root.appendingPathComponent(owner + "-home")
        data = root.appendingPathComponent("support/Data/" + owner)
        role = root.appendingPathComponent(
            "support/Extensions/" + owner + "/edith-host-2/arm64/1.0.0/" + owner
                + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/"
                + owner + "/"
                + ([
                    "music", "plugins", "studio", "usage", "herdr", "machines", "attention",
                    "companion", "codeStats",
                ].contains(owner) ? "app" : "helper")
                + ".bundle")
        for directory in [root, home, data, role, root.appendingPathComponent("Fixture.app")] {
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

    public func admit() throws -> WorkerFixtureAdmission? {
        try WorkerFixtureAdmission.admit(
            extensionID: owner, context: context as NSDictionary, environment: environment,
            hostIdentifier: identifier, hostBundle: root.appendingPathComponent("Fixture.app"),
            roleDirectory: role,
            roleIdentifier: "com.pulkit.edith.extensions." + owner + "."
                + ([
                    "music", "plugins", "studio", "usage", "herdr", "machines", "attention",
                    "companion", "codeStats",
                ].contains(owner) ? "app" : "helper"),
            version: "1.0.0", hostABI: "edith-host-2")
    }

    public func remove() { try? FileManager.default.removeItem(at: root) }
}
