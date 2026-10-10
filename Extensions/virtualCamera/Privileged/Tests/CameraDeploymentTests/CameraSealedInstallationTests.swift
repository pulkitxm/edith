import Darwin
import Foundation
import Testing
@testable import CameraDeployment

@Suite(.serialized) struct CameraSealedInstallationTests {
    private final class Fixture {
        let root: URL
        let source: URL
        let privilege: URL
        var failedCopy = false
        var failedPublished = false
        var wrongTeam = false
        var wrongInstaller = false
        var revision: UInt8 = 1
        let host = "com.pulkit.edith.dev.fixture"
        init(obs: Bool = false) throws {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
                "camera-install-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: temporary, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            root = URL(
                fileURLWithPath: try #require(realpath(temporary.path, nil)).withFreeString())
            source = root.appendingPathComponent("Download/Camera.app")
            privilege = root.appendingPathComponent("privileged.bundle")
            let provider = source.appendingPathComponent(
                "Contents/Library/SystemExtensions/" + host + ".camera.systemextension")
            let embedded = source.appendingPathComponent("Contents/PlugIns/privileged.bundle")
            let driver = source.appendingPathComponent(
                "Contents/Library/Audio/Plug-Ins/HAL/" + host + ".microphone.driver")
            for directory in [
                source.appendingPathComponent("Contents/MacOS"), provider, embedded, privilege,
                driver,
            ] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            }
            if obs {
                try FileManager.default.removeItem(
                    at: source.appendingPathComponent("Contents/Library/SystemExtensions"))
            }
            try Data([1, 2, 3]).write(to: source.appendingPathComponent("Contents/MacOS/Edith"))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: source.appendingPathComponent("Contents/MacOS/Edith").path)
            try writeInfo([
                "CFBundleIdentifier": host + ".cameraCarrier", "CFBundleExecutable": "Edith",
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0.0",
                "EdithContainedRole": "cameraCarrier", "EdithContainedExtensionID": "virtualCamera",
                "EdithHostIdentifier": host, "EdithHostABI": "edith-host-2",
                "EdithExecutableProvenance": String(repeating: "a", count: 64),
                "EdithCameraTransport": obs ? "obs" : "native",
            ])
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func writeInfo(_ info: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: source.appendingPathComponent("Contents/Info.plist"))
        }
        func installer(hostABI: String = "edith-host-2") throws -> CameraSealedInstallation {
            try CameraSealedInstallation(
                configuration: .init(
                    hostIdentifier: host, version: "1.0.0", hostABI: hostABI,
                    destination: root.appendingPathComponent("Installed"),
                    microphoneDestination: root.appendingPathComponent("HAL"), owner: geteuid(),
                    protectedBoundary: root), privilegedBundle: privilege,
                verify: { [self] path in
                    if failedCopy, path.lastPathComponent.hasPrefix(".camera-") {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    if failedPublished, path.path.contains("/Installed/"),
                        path.pathExtension == "app", !path.lastPathComponent.hasPrefix(".camera-")
                    {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let identifier: String
                    let digest: UInt8
                    if path.lastPathComponent == "privileged.bundle" {
                        identifier = "com.pulkit.edith.extensions.virtualCamera.privileged"
                        digest = wrongInstaller && path != privilege ? 2 : 1
                    } else if path.pathExtension == "systemextension" {
                        identifier = host + ".camera"; digest = revision
                    } else if path.pathExtension == "driver"
                        || path.lastPathComponent.hasPrefix(".camera-microphone-")
                    {
                        identifier = host + ".microphone"; digest = revision
                    } else {
                        identifier = host + ".cameraCarrier"; digest = revision
                    }
                    return .init(
                        identifier: identifier,
                        team: wrongTeam && path != privilege ? "OTHERTEAM1" : "TEAM123456",
                        digest: Data([digest]))
                })
        }
    }

    @Test func currentABIIsAcceptedAndLegacyConfigurationAndCarrierAreRejected() throws {
        let fixture = try Fixture(obs: true)
        _ = try fixture.installer()
        #expect(throws: (any Error).self) { try fixture.installer(hostABI: "edith-host-1") }
        let infoURL = fixture.source.appendingPathComponent("Contents/Info.plist")
        var info = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil)
                as? [String: Any])
        info["EdithHostABI"] = "edith-host-1"
        try fixture.writeInfo(info)
        #expect(throws: (any Error).self) {
            try fixture.installer().installCarrier(source: fixture.source, providerExited: true)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("Installed").path))
    }

    @Test func obsCarrierInstallsOnlyItsVerifiedMicrophone() throws {
        let fixture = try Fixture(obs: true)
        let installer = try fixture.installer()
        let installed = try installer.installCarrier(source: fixture.source, providerExited: true)
        #expect(
            !FileManager.default.fileExists(
                atPath: installed.appendingPathComponent("Contents/Library/SystemExtensions").path))
        #expect(try installer.installMicrophone(carrier: installed))
        #expect(try installer.removeMicrophone())
    }

    @Test func obsCarrierRejectsAnEmbeddedCameraProvider() throws {
        let fixture = try Fixture(obs: true)
        try FileManager.default.createDirectory(
            at: fixture.source.appendingPathComponent("Contents/Library/SystemExtensions"),
            withIntermediateDirectories: true)
        let installer = try fixture.installer()
        #expect(throws: (any Error).self) {
            try installer.installCarrier(source: fixture.source, providerExited: true)
        }
    }

    @Test func sealedInstallWritesVerifiedReceiptAndIsIdempotent() throws {
        let fixture = try Fixture()
        let installer = try fixture.installer()
        let installed = try installer.installCarrier(source: fixture.source, providerExited: true)
        #expect(installed.path.hasPrefix(fixture.root.path))
        #expect(installed.lastPathComponent == fixture.host + ".cameraCarrier.app")
        let receipt = fixture.root.appendingPathComponent(
            "Installed/.receipts/" + fixture.host + ".cameraCarrier.json")
        let values = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: String])
        #expect(values["originalHostSHA256"] == String(repeating: "a", count: 64))
        #expect(values["executableSHA256"]?.count == 64)
        #expect(values["hostABI"] == "edith-host-2")
        let reused = try installer.installCarrier(source: fixture.source, providerExited: false)
        #expect(reused.path == installed.path)
        let modes =
            try FileManager.default.attributesOfItem(atPath: installed.path)[.posixPermissions]
            as? NSNumber
        #expect(((modes?.intValue ?? 0) & 0o022) == 0)
    }

    @Test func copySignatureMismatchCannotPublishInstalledCarrier() throws {
        let fixture = try Fixture()
        fixture.failedCopy = true
        let installer = try fixture.installer()
        #expect(throws: (any Error).self) {
            try installer.installCarrier(source: fixture.source, providerExited: true)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(
                    "Installed/" + fixture.host + ".cameraCarrier.app"
                ).path))
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.root.appendingPathComponent("Installed").path) == [".receipts"])
    }

    @Test func finalSignatureFailureRollsBackPublishedCarrier() throws {
        let fixture = try Fixture()
        fixture.failedPublished = true
        let installer = try fixture.installer()
        #expect(throws: (any Error).self) {
            try installer.installCarrier(source: fixture.source, providerExited: true)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(
                    "Installed/" + fixture.host + ".cameraCarrier.app"
                ).path))
    }

    @Test func wrongTeamOrEmbeddedInstallerIsRejected() throws {
        let fixture = try Fixture()
        fixture.wrongTeam = true
        #expect(throws: (any Error).self) {
            try fixture.installer().installCarrier(source: fixture.source, providerExited: true)
        }
        fixture.wrongTeam = false
        fixture.wrongInstaller = true
        #expect(throws: (any Error).self) {
            try fixture.installer().installCarrier(source: fixture.source, providerExited: true)
        }
    }

    @Test func sourceSymlinksAndMutableInstalledPathsAreRejected() throws {
        let fixture = try Fixture()
        let link = fixture.source.appendingPathComponent("Contents/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.privilege)
        #expect(throws: (any Error).self) {
            try fixture.installer().installCarrier(source: fixture.source, providerExited: true)
        }
        try FileManager.default.removeItem(at: link)
        let installer = try fixture.installer()
        let installed = try installer.installCarrier(source: fixture.source, providerExited: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: installed.path)
        #expect(throws: (any Error).self) {
            try installer.installCarrier(source: fixture.source, providerExited: true)
        }
    }

    @Test func alteredReceiptRequiresProviderExitBeforeRepair() throws {
        let fixture = try Fixture()
        let installer = try fixture.installer()
        let installed = try installer.installCarrier(source: fixture.source, providerExited: true)
        let receipt = fixture.root.appendingPathComponent(
            "Installed/.receipts/" + fixture.host + ".cameraCarrier.json")
        try Data("{}".utf8).write(to: receipt)
        #expect(throws: (any Error).self) {
            try installer.installCarrier(source: fixture.source, providerExited: false)
        }
        let repaired = try installer.installCarrier(source: fixture.source, providerExited: true)
        #expect(repaired.path == installed.path)
    }

    @Test func microphoneCopyIsVerifiedAndRemainsOutsideBaseApp() throws {
        let fixture = try Fixture()
        let installer = try fixture.installer()
        let installed = try installer.installCarrier(source: fixture.source, providerExited: true)
        #expect(try installer.installMicrophone(carrier: installed))
        #expect(try !installer.installMicrophone(carrier: installed))
        let path = fixture.root.appendingPathComponent("HAL/" + fixture.host + ".microphone.driver")
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test func invalidMetadataAndAdHocSignaturesAreRejected() throws {
        let fixture = try Fixture()
        try fixture.writeInfo([
            "CFBundleIdentifier": fixture.host + ".cameraCarrier", "CFBundleExecutable": "Edith",
        ])
        #expect(throws: (any Error).self) {
            try fixture.installer().installCarrier(source: fixture.source, providerExited: true)
        }
        #expect(throws: (any Error).self) {
            try CameraSealedInstallation.signature(fixture.privilege)
        }
    }
}

private extension UnsafeMutablePointer where Pointee == CChar {
    func withFreeString() -> String {
        defer { free(self) }
        return String(cString: self)
    }
}
