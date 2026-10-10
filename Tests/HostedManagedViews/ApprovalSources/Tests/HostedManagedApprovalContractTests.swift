import Foundation
import Testing
@testable import HostedManagedApprovalContract

private let identifier = "com.pulkit.edith.tests.worker-00000000-0000-4000-8000-000000000001"
private let source = String(repeating: "a", count: 40)
private func environment() -> [String: String] {
    [
        "GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS", "RUNNER_ENVIRONMENT": "github-hosted",
        "GITHUB_REPOSITORY": "pulkitxm/edith", "GITHUB_ACTOR_ID": "65671483",
        "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REF": "refs/heads/feat/extension-marketplace",
        "GITHUB_SHA": source, "EDITH_HOSTED_MANAGED_VIEWS": "1",
    ]
}
private func route(
    owner: String = "music", host: String = identifier, directory: String = "/synthetic"
) -> HostedManagedApprovalRoute {
    HostedManagedApprovalRoute(
        schema: 1, extensionID: owner, hostIdentifier: host, directory: directory,
        sourceCommit: source, version: "1.0.0", hostABI: "edith-host-2",
        sourceFingerprint: String(repeating: "b", count: 64),
        packageSHA256: String(repeating: "c", count: 64))
}
private func identity(
    _ route: HostedManagedApprovalRoute, worker: String? = nil, point: String? = nil,
    label: String? = nil
) -> HostedManagedApprovalIdentity {
    HostedManagedApprovalIdentity(
        identifier: "public-owned-identity", workerIdentifier: worker ?? route.workerIdentifier,
        extensionPoint: point ?? route.extensionPoint, label: label ?? route.expectedLabel)
}

@Test func hostedApprovalRequiresExactDisposableRunnerActorRefAndSource() throws {
    let route = route()
    try route.validate(environment: environment())
    for key in environment().keys {
        var missing = environment(); missing.removeValue(forKey: key)
        #expect(throws: HostedManagedApprovalError.untrustedRunner) {
            try route.validate(environment: missing)
        }
        var foreign = environment(); foreign[key] = "foreign"
        #expect(throws: HostedManagedApprovalError.untrustedRunner) {
            try route.validate(environment: foreign)
        }
    }
    for ref in [
        "refs/heads/main", "refs/heads/feat/hosted-managed-view-runner",
        "refs/heads/feat/hosted-managed-view-execution",
    ] {
        var values = environment(); values["GITHUB_REF"] = ref
        try route.validate(environment: values)
    }
    var appActor = environment(); appActor["GITHUB_ACTOR_ID"] = "320458784"
    try route.validate(environment: appActor)
}

@Test func allKnownOwnersRequireTheirExactSyntheticHostAndPublicPoint() throws {
    #expect(HostedManagedApprovalRoute.owners.count == 39)
    let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "routes.json")
    let routes = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as! [String: Any]
    let owners = routes["owners"] as! [[String: Any]]
    #expect(Set(owners.compactMap { $0["id"] as? String }) == HostedManagedApprovalRoute.owners)
    for owner in HostedManagedApprovalRoute.owners {
        let host =
            owner == "calendar"
            ? identifier.replacingOccurrences(of: "worker-", with: "remote-") : identifier
        let value = route(owner: owner, host: host)
        try value.validate(environment: environment())
        #expect(try value.validateIdentities([]) == nil)
        #expect(try value.validateIdentities([identity(value)]) == "public-owned-identity")
        for candidate in [
            identity(value, worker: "foreign.worker"),
            identity(value, point: "foreign.ExtensionUI"),
            identity(value, label: "Edith foreign"),
        ] {
            #expect(throws: HostedManagedApprovalError.ambiguousIdentity) {
                try value.validateIdentities([candidate])
            }
        }
        #expect(throws: HostedManagedApprovalError.ambiguousIdentity) {
            try value.validateIdentities([identity(value), identity(value)])
        }
    }
    for value in [
        route(owner: "unknown"), route(host: "com.pulkit.edith"), route(owner: "calendar"),
        route(host: identifier.uppercased()),
    ] {
        #expect(throws: HostedManagedApprovalError.invalidRoute) {
            try value.validate(environment: environment())
        }
    }
}

@Test func browserHostMayExposeOnlyTheOwnedExtensionPoint() throws {
    let route = route()
    let root = URL(fileURLWithPath: route.directory)
    try route.validateApplicationPaths(
        bundle: root.appendingPathComponent("Fixture.app"),
        executable: root.appendingPathComponent("Fixture.app/Contents/MacOS/Edith"))
    for (bundle, executable) in [
        (
            root.appendingPathComponent("Duplicate.app"),
            root.appendingPathComponent("Duplicate.app/Contents/MacOS/Edith")
        ),
        (
            root.appendingPathComponent("Fixture.app"),
            root.appendingPathComponent("Fixture.app/Contents/MacOS/other")
        ), (root.appendingPathComponent("Fixture.app"), nil),
    ] {
        #expect(throws: HostedManagedApprovalError.invalidApplication) {
            try route.validateApplicationPaths(bundle: bundle, executable: executable)
        }
    }
    let descriptor: [String: Any] = [
        "EXVersion": 1, route.extensionPoint: ["EXExtensionPointName": "ExtensionUI"],
    ]
    try route.validateApplication(identifier: route.hostIdentifier, descriptor: descriptor)
    #expect(throws: HostedManagedApprovalError.invalidApplication) {
        try route.validateApplication(identifier: "com.pulkit.edith", descriptor: descriptor)
    }
    var extra = descriptor; extra["foreign.ExtensionUI"] = ["EXExtensionPointName": "ExtensionUI"]
    #expect(throws: HostedManagedApprovalError.invalidApplication) {
        try route.validateApplication(identifier: route.hostIdentifier, descriptor: extra)
    }
    var boolean = descriptor; boolean["EXVersion"] = true
    #expect(throws: HostedManagedApprovalError.invalidApplication) {
        try route.validateApplication(identifier: route.hostIdentifier, descriptor: boolean)
    }
}

@Test func publicToggleSelectionRejectsAmbiguousForeignEnabledOrUnavailableControls() throws {
    func control(
        labels: [String] = ["Edith music"], value: String? = "0", enabled: Bool = true,
        hittable: Bool = true, kind: String = "checkbox"
    ) -> HostedManagedApprovalControl {
        HostedManagedApprovalControl(
            kind: kind, labels: labels, value: value, enabled: enabled, hittable: hittable)
    }
    #expect(
        try HostedManagedApprovalSelection.select(
            [control(labels: ["Edith calendar"]), control()], expectedLabel: "Edith music") == 1)
    for controls in [
        [], [control(), control()], [control(labels: ["Edith music other"])],
        Array(repeating: control(), count: 129),
    ] {
        #expect(throws: HostedManagedApprovalError.ambiguousControl) {
            try HostedManagedApprovalSelection.select(controls, expectedLabel: "Edith music")
        }
    }
    for value in [
        control(value: "1"), control(value: nil), control(enabled: false), control(hittable: false),
        control(kind: "button"),
    ] {
        #expect(throws: HostedManagedApprovalError.unsupportedControl) {
            try HostedManagedApprovalSelection.select([value], expectedLabel: "Edith music")
        }
    }
}

@Test func boundedOwnedRouteReadRejectsSymlinksHardlinksWrongModeSizeAndExtraKeys() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "approval-contract-" + UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("managed-route.json")
    let route = route(directory: directory.path)
    var object: [String: Any] = [
        "schema": 1, "extensionID": route.extensionID, "hostIdentifier": route.hostIdentifier,
        "directory": route.directory, "sourceCommit": route.sourceCommit, "version": route.version,
        "hostABI": route.hostABI, "sourceFingerprint": route.sourceFingerprint,
        "packageSHA256": route.packageSHA256, "location": "main", "section": "music",
        "factoryOverlay": false,
    ]
    func write(_ data: Data) throws {
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    try write(JSONSerialization.data(withJSONObject: object))
    #expect(
        try HostedManagedApprovalRoute.load(directory: directory, environment: environment())
            == route)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    #expect(throws: (any Error).self) {
        try HostedManagedApprovalRoute.load(directory: directory, environment: environment())
    }
    try write(Data(repeating: 1, count: 16_385))
    #expect(throws: (any Error).self) {
        try HostedManagedApprovalRoute.load(directory: directory, environment: environment())
    }
    object["extra"] = "foreign"
    try write(JSONSerialization.data(withJSONObject: object))
    #expect(throws: (any Error).self) {
        try HostedManagedApprovalRoute.load(directory: directory, environment: environment())
    }
    object.removeValue(forKey: "extra")
    try write(JSONSerialization.data(withJSONObject: object))
    let link = directory.appendingPathComponent("hardlink")
    try FileManager.default.linkItem(at: file, to: link)
    #expect(throws: (any Error).self) {
        try HostedManagedApprovalRoute.load(directory: directory, environment: environment())
    }
    try FileManager.default.removeItem(at: link)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: link)
    #expect(throws: (any Error).self) {
        try HostedManagedApprovalRoute.load(directory: directory, environment: environment())
    }
}

@Test func producerApprovalReceiptRequiresExactSourcePackageAndOwnedHostGeneration() throws {
    let route = route()
    let receipt = HostedManagedApprovalReceipt(
        schema: 1, sourceCommit: route.sourceCommit, extensionID: route.extensionID,
        selectedVersion: route.version, hostABI: route.hostABI,
        sourceFingerprint: route.sourceFingerprint, packageSHA256: route.packageSHA256,
        hostIdentifier: route.hostIdentifier, workerIdentifier: route.workerIdentifier,
        extensionPointIdentifier: route.extensionPoint, expectedLabel: route.expectedLabel,
        hostPID: 222, hostGeneration: "101.2", outcome: "approved", publicBrowser: true,
        publicDiscovery: true, ownedBrowserClosed: true, activationPolicyRestored: true,
        managedViewReady: false)
    let data = try JSONEncoder().encode(receipt)
    #expect(
        try HostedManagedApprovalReceipt.approved(
            data, route: route, hostPID: 222, hostGeneration: "101.2") == receipt)
    for (pid, generation) in [(223, "101.2"), (222, "102.2"), (1, "101.2")] {
        #expect(throws: (any Error).self) {
            try HostedManagedApprovalReceipt.approved(
                data, route: route, hostPID: Int32(pid), hostGeneration: generation)
        }
    }
    let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    for (key, value) in [
        ("sourceCommit", String(repeating: "d", count: 40) as Any), ("extensionID", "calendar"),
        ("selectedVersion", "2.0.0"), ("hostABI", "old"), ("sourceFingerprint", "stale"),
        ("packageSHA256", "foreign"), ("hostIdentifier", "com.pulkit.edith"),
        ("workerIdentifier", "foreign.worker"), ("extensionPointIdentifier", "foreign.ExtensionUI"),
        ("expectedLabel", "Edith foreign"), ("outcome", "ready"), ("publicDiscovery", false),
        ("ownedBrowserClosed", false), ("activationPolicyRestored", false),
        ("managedViewReady", true),
        ("publicDiscovery", 1), ("extra", "unowned"),
    ] {
        var changed = original; changed[key] = value
        let bytes = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: (any Error).self) {
            try HostedManagedApprovalReceipt.approved(
                bytes, route: route, hostPID: 222, hostGeneration: "101.2")
        }
    }
    #expect(throws: (any Error).self) {
        try HostedManagedApprovalReceipt.approved(
            Data(repeating: 1, count: 16_385), route: route, hostPID: 222, hostGeneration: "101.2")
    }
}

@Test func applicationEnvironmentUsesOnlyOwnedCanonicalSyntheticDirectories() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "approval-environment-" + UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    for owner in ["music", "calendar"] {
        let home = directory.appendingPathComponent(
            owner == "calendar" ? "synthetic-data" : owner + "-home")
        let paths = [
            home, directory.appendingPathComponent("tmp"), home.appendingPathComponent(".config"),
            home.appendingPathComponent(".cache"), home.appendingPathComponent(".local"),
            home.appendingPathComponent(".local/share"),
        ]
        for path in paths where !FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.createDirectory(
                at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        }
        let host =
            owner == "calendar"
            ? identifier.replacingOccurrences(of: "worker-", with: "remote-") : identifier
        let route = route(owner: owner, host: host, directory: directory.path)
        var inputs = environment()
        inputs["HOME"] = "/foreign"; inputs["CFFIXED_USER_HOME"] = "/foreign-container"
        inputs["TMPDIR"] = "/foreign-tmp"; inputs["GH_TOKEN"] = "synthetic-secret"
        inputs["EDITH_EXTENSION_FIXTURE_HOME"] = "/foreign-fixture"
        let output = try route.applicationEnvironment(inputs)
        #expect(output["HOME"] == home.path)
        #expect(output["EDITH_EXTENSION_FIXTURE_HOME"] == home.path)
        #expect(output["EDITH_APPLICATION_IDENTIFIER"] == host)
        #expect(output["EDITH_SHARED_DEFAULTS_SUITE"] == host)
        #expect(output["CFFIXED_USER_HOME"] == nil && output["GH_TOKEN"] == nil)
        #expect(output["TMPDIR"] == directory.appendingPathComponent("tmp").path)
        let cache = home.appendingPathComponent(".cache")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.path)
        #expect(throws: (any Error).self) { try route.applicationEnvironment(inputs) }
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(
            at: cache, withDestinationURL: home.appendingPathComponent(".config"))
        #expect(throws: (any Error).self) { try route.applicationEnvironment(inputs) }
        try FileManager.default.removeItem(at: cache)
    }
}

@Test func hostedDirectoryIsTheExactAccountApplicationsUUIDWithoutNestedOrForeignPaths() throws {
    let home = URL(fileURLWithPath: "/synthetic-account")
    let suffix = "00000000-0000-4000-8000-000000000001"
    let directory = home.appendingPathComponent("Applications/Edith Managed Views " + suffix)
    try route(directory: directory.path).validateHostedDirectory(accountHome: home)
    for path in [
        directory.appendingPathComponent("nested").path,
        "/foreign/Applications/Edith Managed Views " + suffix,
        home.appendingPathComponent("Applications/Edith Managed Views other").path,
    ] {
        #expect(throws: HostedManagedApprovalError.invalidRoute) {
            try route(directory: path).validateHostedDirectory(accountHome: home)
        }
    }
}
