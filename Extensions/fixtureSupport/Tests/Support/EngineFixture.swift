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

    public func admit() throws -> WorkerFixtureAdmission? {
        try WorkerFixtureAdmission.admit(
            extensionID: owner, context: context as NSDictionary, environment: environment,
            hostIdentifier: identifier, hostBundle: root.appendingPathComponent("Fixture.app"),
            roleDirectory: role,
            roleIdentifier: "com.pulkit.edith.extensions." + owner + "."
                + (owner == "music" ? "app" : "helper"),
            version: "1.0.0", hostABI: "edith-host-2")
    }

    public func remove() { try? FileManager.default.removeItem(at: root) }
}
