import Foundation
import Testing
@testable import ManagedViewContract

private let uuid = "00000000-0000-4000-8000-000000000001"
private func input(owner: String = "plugins") -> NSMutableDictionary {
    let host = "com.pulkit.edith.tests.worker-" + uuid
    return [
        "remoteUI": true, "uiOnly": false, "extensionID": owner,
        "hostIdentifier": host, "defaultsSuite": host + ".extension." + owner + ".worker",
        "presentationID": uuid, "location": "main", "section": owner,
        "version": "1.0.0", "hostABI": "worker-2",
        "hostedManagedFixture": [
            "schema": 1, "sourceCommit": String(repeating: "a", count: 40),
            "selectedVersion": "1.0.0", "hostABI": "worker-2",
            "sourceFingerprint": String(repeating: "b", count: 64),
            "roleDirectory": "/owned/ExtensionWorker.appex/Contents/Resources/Payload/" + owner
                + "/app.bundle",
        ],
    ]
}
private func accepts(_ values: NSDictionary, owner: String = "plugins") -> Bool {
    HostedManagedFactoryAdmission.accepts(
        values, extensionID: owner,
        rolePath: "/owned/ExtensionWorker.appex/Contents/Resources/Payload/" + owner
            + "/app.bundle",
        roleVersion: "1.0.0", roleABI: "worker-2",
        workerIdentifier: "com.pulkit.edith.tests.worker-" + uuid + ".extension." + owner
            + ".worker")
}

@Test func onlyTwoReviewedFactoriesAdmitExactAuthenticatedFixtureMetadata() {
    #expect(accepts(input()))
    #expect(accepts(input(owner: "studio"), owner: "studio"))
    #expect(!accepts(input(owner: "music"), owner: "music"))
    for (key, value) in [
        ("hostIdentifier", "com.pulkit.edith" as Any), ("presentationID", "invalid"),
        ("location", "settings"), ("section", "other"), ("uiOnly", true), ("remoteUI", false),
        ("remoteUI", 1), ("uiOnly", 0), ("defaultsSuite", "foreign"), ("version", "2.0.0"),
        ("hostABI", "other"),
    ] {
        let values = input(); values[key] = value
        #expect(!accepts(values))
    }
    for (key, value) in [
        ("sourceCommit", "stale" as Any), ("sourceFingerprint", "invalid"),
        ("roleDirectory", "/foreign/app.bundle"), ("selectedVersion", "2.0.0"),
        ("hostABI", "wrong"), ("schema", true), ("extra", "unknown"),
    ] {
        let values = input()
        let fixture = NSMutableDictionary(
            dictionary: values["hostedManagedFixture"] as! [String: Any])
        fixture[key] = value; values["hostedManagedFixture"] = fixture
        #expect(!accepts(values))
    }
}

private func route(id: String, directory: String = "/synthetic") -> HostedManagedViewRoute {
    HostedManagedViewRoute(
        schema: 1, extensionID: id,
        location: HostedManagedViewRoute.settingsOwners.contains(id) ? "settings" : "main",
        section: id == "notchShelf" ? "extension" : id, version: "1.0.0", hostABI: "worker-2",
        sourceFingerprint: String(repeating: "a", count: 64),
        sourceCommit: String(repeating: "b", count: 40),
        hostIdentifier: "com.pulkit.edith.tests." + (id == "calendar" ? "remote-" : "worker-")
            + uuid,
        directory: directory, factoryOverlay: ["plugins", "studio"].contains(id))
}

@Test func everyClosedOriginalRouteRejectsWrongOwnerVersionAndFingerprint() throws {
    #expect(HostedManagedViewRoute.owners.count == 39)
    for id in HostedManagedViewRoute.owners {
        let route = route(id: id)
        try route.validate(
            extensionID: id, version: "1.0.0", hostABI: "worker-2",
            sourceFingerprint: String(repeating: "a", count: 64))
        #expect(throws: (any Error).self) {
            try route.validate(
                extensionID: "unknown", version: "1.0.0", hostABI: "worker-2",
                sourceFingerprint: route.sourceFingerprint)
        }
        #expect(throws: (any Error).self) {
            try route.validate(
                extensionID: id, version: "2.0.0", hostABI: "worker-2",
                sourceFingerprint: route.sourceFingerprint)
        }
        #expect(throws: (any Error).self) {
            try route.validate(
                extensionID: id, version: "1.0.0", hostABI: "worker-2",
                sourceFingerprint: String(repeating: "c", count: 64))
        }
    }
}

@Test func ownedRouteFileRejectsSymlinkWrongModeExtraKeysAndSelectedMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "managed-contract-" + UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("managed-route.json")
    let original = route(id: "plugins", directory: directory.path)
    func write(_ bytes: Data) throws {
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    try write(JSONEncoder().encode(original))
    #expect(try HostedManagedViewRoute.load(directory: directory) == original)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    #expect(throws: (any Error).self) { try HostedManagedViewRoute.load(directory: directory) }
    try write(JSONEncoder().encode(original))
    var values = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    values["extra"] = "unowned"
    try write(JSONSerialization.data(withJSONObject: values))
    #expect(throws: (any Error).self) { try HostedManagedViewRoute.load(directory: directory) }
    try FileManager.default.removeItem(at: file)
    let target = directory.appendingPathComponent("target")
    try JSONEncoder().encode(original).write(to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(throws: (any Error).self) { try HostedManagedViewRoute.load(directory: directory) }
}
