import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostRequirementPackageInspectionTests {
    @Test func absentIncompatibleAndCorruptMetadataAreHonestAndReadonly() throws {
        let fixture = try RequirementPackageFixture()
        defer { fixture.remove() }
        #expect(
            try fixture.inspector().inspect(id: "systemStats", enabled: false, active: false)
                == .absent)
        try fixture.writeState(abi: "incompatible")
        #expect(
            try fixture.inspector().inspect(id: "systemStats", enabled: false, active: false)
                == .incompatible)
        try Data("invalid".utf8).write(to: fixture.root.appendingPathComponent("installed.json"))
        let before = try Data(contentsOf: fixture.root.appendingPathComponent("installed.json"))
        if case .invalid = try fixture.inspector().inspect(
            id: "systemStats", enabled: false, active: false)
        {
        } else {
            Issue.record("Corrupt installed metadata was accepted")
        }
        #expect(
            try Data(contentsOf: fixture.root.appendingPathComponent("installed.json")) == before)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(".operation.lock").path))
    }

    @Test func inactiveSealedPackageUsesRealSignatureChecksWithoutLoadingCode() throws {
        let fixture = try RequirementPackageFixture()
        defer { fixture.remove() }
        try fixture.writeState()
        try fixture.makePackage()
        if case .invalid = try fixture.inspector().inspect(
            id: "systemStats", enabled: false, active: false)
        {
        } else {
            Issue.record("Unsigned package was accepted")
        }
        try fixture.sign()
        #expect(
            try fixture.inspector().inspect(id: "systemStats", enabled: false, active: false)
                == .installed(version: "1.0.0", enabled: false, active: false))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        #expect(names == ["installed.json", "systemStats"])
        try Data("tampered".utf8).write(
            to: fixture.role.appendingPathComponent("Contents/Resources/unsealed"))
        if case .invalid = try fixture.inspector().inspect(
            id: "systemStats", enabled: false, active: false)
        {
        } else {
            Issue.record("Modified signed package was accepted")
        }
    }

    @Test func unownedApplicationsCannotJoinAnInspectedPackage() throws {
        let fixture = try RequirementPackageFixture()
        defer { fixture.remove() }
        try fixture.writeState(); try fixture.makePackage(); try fixture.sign()
        let auxiliary = fixture.payload.appendingPathComponent("CameraCarrier.app")
        try FileManager.default.createDirectory(at: auxiliary, withIntermediateDirectories: true)
        if case .invalid = try fixture.inspector().inspect(
            id: "systemStats", enabled: false, active: false)
        {
        } else {
            Issue.record("Unowned auxiliary executable was accepted")
        }
    }

    @Test func missingExpectedRolesCannotBeInspectedAsCompatible() throws {
        let fixture = try RequirementPackageFixture()
        defer { fixture.remove() }
        try fixture.writeState(); try fixture.makePackage(); try fixture.sign()
        if case .invalid = try fixture.inspector(roles: ["app"]).inspect(
            id: "systemStats", enabled: false, active: false)
        {
        } else {
            Issue.record("Missing expected role was accepted")
        }
    }
}

private struct RequirementPackageFixture {
    let root: URL
    let host = "com.pulkit.edith.tests.requirements"
    let package: ExtensionPackage
    var store: ExtensionPackageStore { .init(root: root) }
    var payload: URL { store.directory(for: package).appendingPathComponent(package.id) }
    var role: URL { payload.appendingPathComponent("helper.bundle") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "requirement-package-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        package = Self.package(abi: "edith-host-2")
    }
    static func package(abi: String) -> ExtensionPackage {
        .init(
            id: "systemStats", version: "1.0.0", hostABI: abi,
            downloadURL: URL(
                string:
                    "https://github.com/synthetic/fixture/releases/download/1.0.0/systemStats.zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 4096)
    }
    func inspector(host: String? = nil, roles: Set<String> = ["helper"])
        -> HostRequirementPackageInspection
    {
        .init(
            store: store, hostABI: "edith-host-2", architecture: "arm64",
            systemVersion: .init(major: 15),
            hostIdentifier: host ?? self.host, requiredRoles: roles, policy: .development)
    }
    func writeState(abi: String = "edith-host-2") throws {
        try JSONEncoder().encode([Self.package(abi: abi)]).write(
            to: root.appendingPathComponent("installed.json"))
    }
    func makePackage() throws {
        let info: [String: Any] = [
            "CFBundleExecutable": "fixture",
            "CFBundleIdentifier": "com.pulkit.edith.extensions.systemStats.helper",
            "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1.0.0", "EdithHostABI": "edith-host-2",
        ]
        let macos = role.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: role.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: role.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("fixture"))
        try JSONEncoder().encode(ExtensionPayloadManifest(package: package)).write(
            to: payload.appendingPathComponent("package.json"))
    }
    func sign() throws {
        let entitlements = root.appendingPathComponent("entitlements.plist")
        defer { try? FileManager.default.removeItem(at: entitlements) }
        for (bundle, values) in [(role, [String: Bool]())] {
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
                .write(to: entitlements)
            let process = Process();
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = [
                "--force", "--sign", "-", "--entitlements", entitlements.path, bundle.path,
            ]
            process.standardOutput = FileHandle.nullDevice;
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
