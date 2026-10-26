import Foundation
import Testing
@testable import VirtualCameraExtension

@Suite struct CameraSelectedPackageLayoutTests {
    struct Fixture {
        let root: URL
        let role: URL
        let carrier: URL
        let privileged: URL
        let host: String

        init(
            hostIdentifier: String = "com.pulkit.edith.tests.worker-" + UUID().uuidString,
            roleSuffix: String =
                "app.bundle",
            manifestVersion: String = "1.0.0", carrierChanges: [String: String] = [:],
            privilegedVersion: String = "1.0.0"
        ) throws {
            host = hostIdentifier
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "camera-layout-" + UUID().uuidString
            ).resolvingSymlinksInPath()
            let package = root.appendingPathComponent("1.0.0/virtualCamera")
            role = package.appendingPathComponent(roleSuffix)
            carrier = package.appendingPathComponent("CameraCarrier.app")
            privileged = role.deletingLastPathComponent().appendingPathComponent(
                "privileged.bundle")
            try Self.bundle(
                role,
                [
                    "CFBundleIdentifier": "com.pulkit.edith.extensions.virtualCamera.app",
                    "CFBundleExecutable": "Runtime", "CFBundleShortVersionString": "1.0.0",
                    "EdithHostABI": "edith-host-4",
                ])
            var carrierInfo = [
                "CFBundleIdentifier": host + ".cameraCarrier", "CFBundleExecutable": "Edith",
                "CFBundleShortVersionString": "1.0.0", "EdithHostABI": "edith-host-4",
                "EdithHostIdentifier": host, "EdithContainedExtensionID": "virtualCamera",
                "EdithContainedRole": "cameraCarrier",
            ]
            carrierInfo.merge(carrierChanges) { _, changed in changed }
            try Self.bundle(carrier, carrierInfo)
            try Self.bundle(
                privileged,
                [
                    "CFBundleIdentifier": "com.pulkit.edith.extensions.virtualCamera.privileged",
                    "CFBundleExecutable": "Runtime",
                    "CFBundleShortVersionString": privilegedVersion,
                    "EdithHostABI": "edith-host-4",
                ])
            try JSONSerialization.data(withJSONObject: [
                "id": "virtualCamera", "version": manifestVersion, "hostABI": "edith-host-4",
                "architecture": "arm64", "dependencies": [],
            ]).write(to: role.deletingLastPathComponent().appendingPathComponent("package.json"))
        }

        static func bundle(_ url: URL, _ info: [String: String]) throws {
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0
            ).write(to: contents.appendingPathComponent("Info.plist"))
            try Data().write(
                to: contents.appendingPathComponent("MacOS/" + info["CFBundleExecutable"]!))
        }

        func resolve() throws -> CameraSelectedPackageLayout {
            try CameraSelectedPackageLayout(
                roleURL: role, hostIdentifier: host)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func currentFlatLayoutKeepsCarrierAndPrivilegeBesideLoadedRole() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let selected = try fixture.resolve()
        #expect(selected.carrier.path == fixture.carrier.path)
        #expect(selected.privileged.path == fixture.privileged.path)
        #expect(
            selected.carrier.deletingLastPathComponent()
                == selected.privileged.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: selected.carrier.path))
    }

    @Test func legacyForeignAndIncompleteRoleLayoutsAreRejected() throws {
        for suffix in [
            "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/virtualCamera/app.bundle",
            "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/other/app.bundle",
            "ExtensionCarrier.app/Contents/Resources/Payload/virtualCamera/app.bundle",
        ] {
            let fixture = try Fixture(roleSuffix: suffix)
            defer { fixture.remove() }
            #expect(throws: (any Error).self) { try fixture.resolve() }
        }
    }

    @Test func carrierMetadataCannotSelectForeignHostOwnerRoleVersionOrABI() throws {
        for changes in [
            ["CFBundleIdentifier": "com.pulkit.edith.cameraCarrier"],
            ["EdithHostIdentifier": "com.pulkit.edith"],
            ["EdithContainedExtensionID": "other"], ["EdithContainedRole": "cameraProvider"],
            ["CFBundleShortVersionString": "1.1.0"], ["EdithHostABI": "edith-host-1"],
            ["CFBundleExecutable": "other"],
        ] {
            let fixture = try Fixture(carrierChanges: changes)
            defer { fixture.remove() }
            #expect(throws: (any Error).self) { try fixture.resolve() }
        }
    }

    @Test func manifestAndPrivilegedVersionsMustMatchTheActualLoadedRole() throws {
        for values in [("1.1.0", "1.0.0"), ("1.0.0", "1.1.0")] {
            let fixture = try Fixture(
                manifestVersion: values.0, privilegedVersion: values.1)
            defer { fixture.remove() }
            #expect(throws: (any Error).self) { try fixture.resolve() }
        }
    }

    @Test func missingMalformedOversizedAndLinkedManifestsAreRejected() throws {
        for kind in ["missing", "malformed", "oversized", "linked"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let manifest = fixture.role.deletingLastPathComponent().appendingPathComponent(
                "package.json")
            switch kind {
            case "missing": try FileManager.default.removeItem(at: manifest)
            case "malformed": try Data("invalid".utf8).write(to: manifest)
            case "oversized": try Data(repeating: 32, count: 16_385).write(to: manifest)
            default:
                let moved = fixture.root.appendingPathComponent("moved.json")
                try FileManager.default.moveItem(at: manifest, to: moved)
                try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: moved)
            }
            #expect(throws: (any Error).self) { try fixture.resolve() }
        }
    }

    @Test func missingCarrierCannotFallBackToANeighboringVersion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let neighbor = fixture.root.appendingPathComponent("1.1.0/virtualCamera/CameraCarrier.app")
        try FileManager.default.createDirectory(
            at: neighbor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.carrier, to: neighbor)
        #expect(throws: (any Error).self) { try fixture.resolve() }
    }

    @Test func symlinkedCarrierPrivilegeAndRoleRootsAreRejected() throws {
        for target in ["carrier", "privileged", "role"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            if target == "role" {
                let alias = fixture.root.appendingPathComponent("alias")
                try FileManager.default.createSymbolicLink(
                    at: alias, withDestinationURL: fixture.role)
                #expect(throws: (any Error).self) {
                    try CameraSelectedPackageLayout(
                        roleURL: alias, hostIdentifier: fixture.host)
                }
            } else {
                let selected = target == "carrier" ? fixture.carrier : fixture.privileged
                let moved = fixture.root.appendingPathComponent(target + "-moved")
                try FileManager.default.moveItem(at: selected, to: moved)
                try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: moved)
                #expect(throws: (any Error).self) { try fixture.resolve() }
            }
        }
    }
}
