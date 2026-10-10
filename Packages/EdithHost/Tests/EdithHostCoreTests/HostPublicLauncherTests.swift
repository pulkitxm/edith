import Darwin
import Foundation
import Testing

@testable import EdithHostCore

@Suite(.serialized) @MainActor struct HostPublicLauncherTests {
    private struct Fixture {
        let root: URL
        let app: URL
        let identifier: String
        let launcher: HostPublicLauncher
    }

    @Test func adHocAdmissionIsLimitedToExactUUIDTestNamespaces() {
        let id = UUID().uuidString
        #expect(HostPublicLauncher.permitsAdHoc("com.pulkit.edith.tests." + id))
        for value in [
            "com.pulkit.edith", "com.pulkit.edith.dev." + id,
            "com.pulkit.edith.tests.sample", "com.pulkit.edith.tests.launcher-" + id,
            "com.pulkit.edith.tests." + id + ".other", "other.tests." + id,
        ] {
            #expect(!HostPublicLauncher.permitsAdHoc(value))
        }
    }

    @Test func signedOriginalLauncherPreservesPublicNamespaceArgumentsInputAndExitCode() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let checked = try fixture.launcher.revalidated(
            hostIdentifier: fixture.identifier,
            teamIdentifier: nil)
        #expect(checked.applicationURL.path.contains("Relocated Public App"))
        #expect(checked.launcherURL.lastPathComponent == "ed")
        let result = try process(
            checked.launcherURL.path, ["usage", "statusline"],
            environment: [
                "PATH": "/usr/bin:/bin", "EDITH_APPLICATION_IDENTIFIER": fixture.identifier,
            ],
            input: Data("synthetic status input".utf8))
        #expect(result.status == 7)
        #expect(
            String(decoding: result.output, as: UTF8.self)
                == fixture.identifier + "|1|" + fixture.identifier + "|usage|statusline")
        #expect(result.error == Data("synthetic status input".utf8))
    }

    @Test func metadataRoundTripsThroughActualConfigurationAndRecoveryOmitsHookCapability() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let identity = try HostIdentity(
            identifier: fixture.identifier,
            supportDirectory: fixture.root.appendingPathComponent("support"))
        var configuration = HostWorkerConfiguration(
            identity: identity, extensionID: "usage",
            version: "1.0.0", publicLauncher: fixture.launcher)
        let decoded = try JSONDecoder().decode(
            HostWorkerConfiguration.self,
            from: JSONEncoder().encode(configuration))
        #expect(decoded.appearance == configuration.appearance)
        #expect(decoded.theme == configuration.theme)
        #expect(decoded.zoom == configuration.zoom)
        #expect(decoded.publicLauncher == fixture.launcher)
        let context = try #require(try decoded.publicLauncherContext(teamIdentifier: nil))
        #expect(context["hostIdentifier"] as? String == fixture.identifier)
        #expect(context["launcherURL"] as? String == fixture.launcher.launcherURL.absoluteString)
        configuration.recoveryOnly = true
        #expect(try configuration.publicLauncherContext(teamIdentifier: nil) == nil)
        try FileManager.default.removeItem(at: fixture.app)
        #expect(try configuration.publicLauncherContext(teamIdentifier: nil) == nil)
        #expect(throws: (any Error).self) { try decoded.publicLauncherContext(teamIdentifier: nil) }
        let missing = HostWorkerConfiguration(
            identity: identity, extensionID: "usage", version: "1")
        #expect(try missing.publicLauncherContext(teamIdentifier: nil) == nil)
    }

    @Test func relocatedAppRequiresFreshHostChosenMetadata() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let moved = fixture.root.appendingPathComponent("Other Location With Spaces.app")
        try FileManager.default.moveItem(at: fixture.app, to: moved)
        #expect(throws: (any Error).self) {
            try fixture.launcher.revalidated(
                hostIdentifier: fixture.identifier, teamIdentifier: nil)
        }
        let fresh = try HostPublicLauncher.capture(
            applicationURL: moved,
            hostIdentifier: fixture.identifier, teamIdentifier: nil)
        #expect(fresh.applicationURL == moved.resolvingSymlinksInPath())
        #expect(
            try fresh.revalidated(hostIdentifier: fixture.identifier, teamIdentifier: nil) == fresh)
    }

    @Test func updateRejectsOldBuildAndHashButFreshMetadataUsesCurrentVersion() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var info = try information(fixture.app)
        info["CFBundleVersion"] = "2"
        try writeInfo(info, app: fixture.app)
        try sign(fixture.app)
        #expect(throws: (any Error).self) {
            try fixture.launcher.revalidated(
                hostIdentifier: fixture.identifier, teamIdentifier: nil)
        }
        let fresh = try HostPublicLauncher.capture(
            applicationURL: fixture.app,
            hostIdentifier: fixture.identifier, teamIdentifier: nil)
        #expect(fresh.buildVersion == "2")
        #expect(fresh.signatureHash != fixture.launcher.signatureHash)
        #expect(
            try fresh.revalidated(hostIdentifier: fixture.identifier, teamIdentifier: nil) == fresh)
    }

    @Test func replacingAnIdenticallySignedAppStillRejectsTheRetiredFileIdentity() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacement = fixture.root.appendingPathComponent("Replacement.app")
        try FileManager.default.copyItem(at: fixture.app, to: replacement)
        try FileManager.default.removeItem(at: fixture.app)
        try FileManager.default.moveItem(at: replacement, to: fixture.app)
        #expect(throws: (any Error).self) {
            try fixture.launcher.revalidated(
                hostIdentifier: fixture.identifier, teamIdentifier: nil)
        }
        let fresh = try HostPublicLauncher.capture(
            applicationURL: fixture.app,
            hostIdentifier: fixture.identifier, teamIdentifier: nil)
        #expect(fresh.signatureHash == fixture.launcher.signatureHash)
        #expect(fresh.bundleFileID != fixture.launcher.bundleFileID)
    }

    @Test(arguments: ["resource", "main", "info", "missing", "permissions", "unsigned"])
    func tamperedMissingAndNonExecutableFilesFailRealSignatureValidation(_ change: String) throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resource = fixture.app.appendingPathComponent("Contents/Resources/ed-launcher")
        switch change {
        case "resource": try Data("#!/bin/sh\nexit 0\n".utf8).write(to: resource)
        case "main":
            try Data("tampered".utf8).write(
                to: fixture.app.appendingPathComponent("Contents/MacOS/Edith"))
        case "info":
            var info = try information(fixture.app); info["CFBundleVersion"] = "tampered"
            try writeInfo(info, app: fixture.app)
        case "missing": try FileManager.default.removeItem(at: resource)
        case "permissions":
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: resource.path)
        default: _ = try process("/usr/bin/codesign", ["--remove-signature", fixture.app.path])
        }
        #expect(throws: (any Error).self) {
            try fixture.launcher.revalidated(
                hostIdentifier: fixture.identifier, teamIdentifier: nil)
        }
    }

    @Test(arguments: ["launcher", "resources", "app", "different-relative-link"])
    func symlinkEscapesNeverBecomeLauncherCapabilities(_ change: String) throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        if change == "app" {
            let other = fixture.root.appendingPathComponent("Other.app")
            try FileManager.default.moveItem(at: fixture.app, to: other)
            try FileManager.default.createSymbolicLink(at: fixture.app, withDestinationURL: other)
        } else if change == "resources" {
            let resources = fixture.app.appendingPathComponent("Contents/Resources")
            try FileManager.default.moveItem(
                at: resources, to: external.appendingPathComponent("Resources"))
            try FileManager.default.createSymbolicLink(
                at: resources, withDestinationURL: external.appendingPathComponent("Resources"))
        } else {
            let link = fixture.app.appendingPathComponent("Contents/MacOS/ed")
            try FileManager.default.removeItem(at: link)
            let destination =
                change == "launcher" ? external.path + "/ed" : "../Resources/./ed-launcher"
            try FileManager.default.createSymbolicLink(
                atPath: link.path, withDestinationPath: destination)
        }
        #expect(throws: (any Error).self) {
            try fixture.launcher.revalidated(
                hostIdentifier: fixture.identifier, teamIdentifier: nil)
        }
    }

    @Test(arguments: [
        "CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType", "EdithExtensionID",
        "EdithContainedRole", "NSExtension",
    ])
    func signedCarrierAndWrongPublicBundleMetadataRejects(_ key: String) throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var info = try information(fixture.app)
        info[key] = key == "NSExtension" ? ["NSExtensionPointIdentifier": "test"] : "foreign"
        if key == "CFBundleExecutable" {
            try FileManager.default.moveItem(
                at: fixture.app.appendingPathComponent("Contents/MacOS/Edith"),
                to: fixture.app.appendingPathComponent("Contents/MacOS/foreign"))
        }
        try writeInfo(info, app: fixture.app)
        try sign(fixture.app)
        #expect(throws: (any Error).self) {
            try HostPublicLauncher.capture(
                applicationURL: fixture.app,
                hostIdentifier: fixture.identifier, teamIdentifier: nil)
        }
    }

    @Test func forgedClosedMetadataWrongTeamAndNonUUIDDevelopmentSignaturesReject() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.launcher))
                as? [String: Any])
        object["executable"] = "/arbitrary/program"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                HostPublicLauncher.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        object.removeValue(forKey: "executable")
        for (key, value) in [
            "version": 2, "launcherSHA256": String(repeating: "0", count: 64),
            "signatureHash": Data(repeating: 0, count: 20).base64EncodedString(),
            "launcherURL": fixture.app.appendingPathComponent("Contents/MacOS/Edith")
                .absoluteString,
        ] as [String: Any] {
            var changed = object; changed[key] = value
            let forged = try JSONDecoder().decode(
                HostPublicLauncher.self,
                from: JSONSerialization.data(withJSONObject: changed))
            #expect(throws: (any Error).self) {
                try forged.revalidated(hostIdentifier: fixture.identifier, teamIdentifier: nil)
            }
        }
        #expect(throws: (any Error).self) {
            try fixture.launcher.revalidated(
                hostIdentifier: fixture.identifier, teamIdentifier: "OTHERTEAM")
        }
        var info = try information(fixture.app)
        let developmentID = "com.pulkit.edith.dev." + UUID().uuidString
        info["CFBundleIdentifier"] = developmentID
        try writeInfo(info, app: fixture.app); try sign(fixture.app)
        #expect(throws: (any Error).self) {
            try HostPublicLauncher.capture(
                applicationURL: fixture.app,
                hostIdentifier: developmentID, teamIdentifier: nil)
        }
    }

    @Test func validRootSignatureWithForeignSigningIdentifierRejects() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let signed = try process(
            "/usr/bin/codesign",
            [
                "--force", "--sign", "-", "--identifier",
                "com.pulkit.edith.tests." + UUID().uuidString, fixture.app.path,
            ])
        #expect(signed.status == 0)
        let verified = try process(
            "/usr/bin/codesign", ["--verify", "--deep", "--strict", fixture.app.path])
        #expect(verified.status == 0)
        #expect(throws: (any Error).self) {
            try HostPublicLauncher.capture(
                applicationURL: fixture.app, hostIdentifier: fixture.identifier,
                teamIdentifier: nil)
        }
    }

    @Test func signedResourceSymlinkCannotSubstituteForRegularOriginalLauncher() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resource = fixture.app.appendingPathComponent("Contents/Resources/ed-launcher")
        let external = fixture.app.appendingPathComponent("Contents/Resources/stored-launcher")
        try FileManager.default.moveItem(at: resource, to: external)
        try FileManager.default.createSymbolicLink(
            atPath: resource.path, withDestinationPath: "stored-launcher")
        try sign(fixture.app)
        #expect(throws: (any Error).self) {
            try HostPublicLauncher.capture(
                applicationURL: fixture.app, hostIdentifier: fixture.identifier,
                teamIdentifier: nil)
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-public-launcher-" + UUID().uuidString)
        let app = root.appendingPathComponent("Relocated Public App With Spaces.app")
        let identifier = "com.pulkit.edith.tests." + UUID().uuidString
        do {
            for path in ["Contents/MacOS", "Contents/Resources"] {
                try FileManager.default.createDirectory(
                    at: app.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            let source = root.appendingPathComponent("fixture.c")
            try Data(
                """
                #include <CoreFoundation/CoreFoundation.h>
                #include <stdio.h>
                #include <stdlib.h>
                int main(int argc, char **argv) {
                    char identifier[256] = {0};
                    CFStringRef value = CFBundleGetIdentifier(CFBundleGetMainBundle());
                    if (!value || !CFStringGetCString(value, identifier, sizeof(identifier), kCFStringEncodingUTF8)) return 8;
                    printf("%s|%s|%s|%s|%s", identifier, getenv("EDITH_CLI"), getenv("EDITH_APPLICATION_IDENTIFIER"), argc > 1 ? argv[1] : "", argc > 2 ? argv[2] : "");
                    char input[4096]; size_t count = fread(input, 1, sizeof(input), stdin);
                    fwrite(input, 1, count, stderr);
                    return 7;
                }
                """.utf8
            ).write(to: source)
            let binary = app.appendingPathComponent("Contents/MacOS/Edith")
            let compiled = try process(
                "/usr/bin/xcrun",
                ["clang", source.path, "-framework", "CoreFoundation", "-o", binary.path])
            guard compiled.status == 0 else { throw HostWorkerError.rejected }
            let original = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(
                    "Resources/ed-launcher")
            let resource = app.appendingPathComponent("Contents/Resources/ed-launcher")
            try FileManager.default.copyItem(at: original, to: resource)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: resource.path)
            try FileManager.default.createSymbolicLink(
                atPath: app.appendingPathComponent("Contents/MacOS/ed").path,
                withDestinationPath: "../Resources/ed-launcher")
            try writeInfo(
                [
                    "CFBundleIdentifier": identifier, "CFBundleExecutable": "Edith",
                    "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                    "CFBundleShortVersionString": "1.0.0",
                ], app: app)
            try sign(app)
            let launcher = try HostPublicLauncher.capture(
                applicationURL: app,
                hostIdentifier: identifier, teamIdentifier: nil)
            return Fixture(root: root, app: app, identifier: identifier, launcher: launcher)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func sign(_ app: URL) throws {
        let result = try process("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        guard result.status == 0 else { throw HostWorkerError.rejected }
        let verified = try process(
            "/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verified.status == 0 else { throw HostWorkerError.rejected }
    }

    private func information(_ app: URL) throws -> [String: Any] {
        try #require(
            PropertyListSerialization.propertyList(
                from: Data(
                    contentsOf:
                        app.appendingPathComponent("Contents/Info.plist")), format: nil)
                as? [String: Any])
    }

    private func writeInfo(_ value: [String: Any], app: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"), options: .atomic)
    }

    private func process(
        _ executable: String, _ arguments: [String],
        environment: [String: String]? = nil, input: Data = Data()
    ) throws
        -> (status: Int32, output: Data, error: Data)
    {
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments; task.environment = environment
        let output = Pipe(), error = Pipe(), stdin = Pipe()
        task.standardOutput = output; task.standardError = error; task.standardInput = stdin
        try task.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let errors = error.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, bytes, errors)
    }
}
