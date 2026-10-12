import Darwin
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostPrivilegedAdmissionTests {
    @Test func signedBundlesAreCopiedAndSealedBeforeAdmission() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let admitted = try fixture.admission.admit(
            source: fixture.bundle, owner: "sample", version: "1.0.0")
        #expect(admitted != fixture.bundle)
        try ExtensionCodeSignature.verifyDevelopment(admitted)
        let attributes = try FileManager.default.attributesOfItem(atPath: admitted.path)
        #expect(attributes[.ownerAccountID] as? NSNumber == NSNumber(value: getuid()))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        try fixture.admission.remove(admitted)
        #expect(!FileManager.default.fileExists(atPath: admitted.path))
    }

    @Test func alteredSignedPayloadIsRejectedBeforeProtectedStorageIsCreated() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try Data("changed".utf8).write(
            to: fixture.bundle.appendingPathComponent("Contents/Resources/value"))
        #expect(throws: MarketplaceError.invalidSignature) {
            try fixture.admission.admit(source: fixture.bundle, owner: "sample", version: "1.0.0")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.path))
    }

    @Test(arguments: ["different", "../sample", ".", "sample/other"])
    func ownerTraversalAndSignedIdentityMismatchAreRejected(owner: String) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        #expect(throws: MarketplaceError.invalidBundle) {
            try fixture.admission.admit(source: fixture.bundle, owner: owner, version: "1.0.0")
        }
    }

    @Test func aSignedVersionMismatchIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        #expect(throws: MarketplaceError.invalidBundle) {
            try fixture.admission.admit(source: fixture.bundle, owner: "sample", version: "2.0.0")
        }
    }

    @Test func signedBundlesWithLinksCannotEnterProtectedStorage() throws {
        let fixture = try Fixture(link: true)
        defer { fixture.clean() }
        #expect(throws: MarketplaceError.invalidBundle) {
            try fixture.admission.admit(source: fixture.bundle, owner: "sample", version: "1.0.0")
        }
    }

    @Test func userWritableProtectedStorageIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try FileManager.default.createDirectory(
            at: fixture.storage, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: fixture.storage.path)
        #expect(throws: MarketplaceError.invalidSignature) {
            try fixture.admission.admit(source: fixture.bundle, owner: "sample", version: "1.0.0")
        }
    }

    @Test func removalCannotEscapeTheProtectedDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        #expect(throws: MarketplaceError.invalidBundle) {
            try fixture.admission.remove(fixture.bundle)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.bundle.path))
    }

    private struct Fixture {
        let root: URL
        let storage: URL
        let bundle: URL
        var admission: HostPrivilegedAdmission {
            .init(
                root: storage, ownerUID: getuid(), verify: ExtensionCodeSignature.verifyDevelopment)
        }
        init(link: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("privilege-" + UUID().uuidString)
            storage = root.appendingPathComponent("Protected")
            bundle = root.appendingPathComponent("sample.bundle")
            let contents = bundle.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"),
                to: contents.appendingPathComponent("MacOS/Runtime"))
            try Data("synthetic".utf8).write(to: contents.appendingPathComponent("Resources/value"))
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.pulkit.edith.extensions.sample.privileged",
                "CFBundleExecutable": "Runtime", "CFBundlePackageType": "BNDL",
                "CFBundleShortVersionString": "1.0.0", "EdithHostABI": HostContract.compatibility,
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            if link {
                try FileManager.default.createSymbolicLink(
                    at: contents.appendingPathComponent("Resources/link"),
                    withDestinationURL: contents.appendingPathComponent("Resources/value"))
            }
            let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign");
            sign.arguments = ["--force", "--sign", "-", bundle.path];
            sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
            try sign.run(); sign.waitUntilExit()
            guard sign.terminationStatus == 0 else { throw MarketplaceError.invalidSignature }
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
