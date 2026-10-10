import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsagePublicLauncherTests {
    @Test func onlyClosedVerifiedPublicLauncherContextSuppliesHookCapability() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Public Fixture's App.app")
        let context = try fixture(app: app)
        let launcher = app.appendingPathComponent("Contents/MacOS/ed")
        #expect(ClaudeStatusLine.publicExecutable(fromVerifiedContext: context) == launcher.path)
        for key in [
            "version", "hostIdentifier", "applicationURL", "launcherURL", "buildVersion",
            "signatureHash", "bundleFileID", "launcherFileID", "launcherSHA256",
        ] {
            let changed = context.mutableCopy() as! NSMutableDictionary
            let metadata =
                (context["publicLauncher"] as! NSDictionary).mutableCopy() as! NSMutableDictionary
            metadata[key] = key == "version" ? 2 : "invalid"
            changed["publicLauncher"] = metadata
            #expect(
                ClaudeStatusLine.publicExecutable(fromVerifiedContext: changed) == nil,
                Comment(rawValue: key))
        }
        let extra = context.mutableCopy() as! NSMutableDictionary
        let metadata =
            (context["publicLauncher"] as! NSDictionary).mutableCopy() as! NSMutableDictionary
        metadata["executable"] = launcher.path
        extra["publicLauncher"] = metadata
        #expect(ClaudeStatusLine.publicExecutable(fromVerifiedContext: extra) == nil)
        let recovering = context.mutableCopy() as! NSMutableDictionary
        recovering["recoveryOnly"] = true
        #expect(ClaudeStatusLine.publicExecutable(fromVerifiedContext: recovering) == nil)
        #expect(
            ClaudeStatusLine.publicExecutable(fromVerifiedContext: [
                "hostIdentifier": context["hostIdentifier"]!, "executable": launcher.path,
            ]) == nil)
        let carrier = root.appendingPathComponent("ExtensionCarrier.app/Contents/MacOS/Edith")
        try FileManager.default.createDirectory(
            at: carrier.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(ClaudeStatusLine.launcher(beside: carrier) == nil)
        var info = try info(app)
        info["EdithExtensionID"] = "usage"
        try writeInfo(info, app: app)
        #expect(ClaudeStatusLine.publicExecutable(fromVerifiedContext: context) == nil)
    }

    @Test func relocatedCurrentPublicLauncherRetainsOriginalOwnedHookAndOptOutBehavior() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalApp = root.appendingPathComponent("Original Public App.app")
        let originalContext = try fixture(app: originalApp)
        let originalPath = try #require(
            ClaudeStatusLine.publicExecutable(fromVerifiedContext: originalContext))
        let suite = "edith.usage.launcher." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = root.appendingPathComponent("settings.json")
        let previous = "printf 'fixture tail'"
        try JSONSerialization.data(withJSONObject: [
            "sample": true, "statusLine": ["type": "command", "command": previous],
        ]).write(to: settings)
        let owner = UsageCLIHookOwner(
            directory: root.appendingPathComponent("owner"), defaults: defaults,
            executable: originalPath)
        #expect(try owner.connect(settings: settings) == .wrapped)
        #expect(
            try ClaudeStatusLine.configuredCommand(settings: settings)
                == ClaudeStatusLine.command(executable: originalPath, wrapping: previous))
        try owner.shutdown()
        #expect(try ClaudeStatusLine.configuredCommand(settings: settings) == previous)
        let movedApp = root.appendingPathComponent("Relocated Public Fixture's App.app")
        try FileManager.default.moveItem(at: originalApp, to: movedApp)
        #expect(ClaudeStatusLine.publicExecutable(fromVerifiedContext: originalContext) == nil)
        var currentInfo = try info(movedApp)
        currentInfo["CFBundleVersion"] = "2"
        try writeInfo(currentInfo, app: movedApp)
        let currentContext = try context(app: movedApp)
        let stale = currentContext.mutableCopy() as! NSMutableDictionary
        let metadata =
            (currentContext["publicLauncher"] as! NSDictionary).mutableCopy()
            as! NSMutableDictionary
        metadata["buildVersion"] = "1"
        stale["publicLauncher"] = metadata
        #expect(ClaudeStatusLine.publicExecutable(fromVerifiedContext: stale) == nil)
        let currentPath = try #require(
            ClaudeStatusLine.publicExecutable(fromVerifiedContext: currentContext))
        let resumed = UsageCLIHookOwner(
            directory: root.appendingPathComponent("owner"), defaults: defaults,
            executable: currentPath)
        try resumed.resumeOwnedHooks()
        let command = try #require(try ClaudeStatusLine.configuredCommand(settings: settings))
        #expect(
            ClaudeStatusLine.wrappedCommand(in: command) == previous
                && !command.contains(originalPath))
        let syntax = Process()
        syntax.executableURL = URL(fileURLWithPath: "/bin/sh")
        syntax.arguments = ["-n", "-c", command]
        syntax.standardOutput = FileHandle.nullDevice
        syntax.standardError = FileHandle.nullDevice
        try syntax.run()
        syntax.waitUntilExit()
        #expect(syntax.terminationReason == .exit && syntax.terminationStatus == 0)
        #expect(try resumed.disconnect(settings: settings) == .restored)
        #expect(try ClaudeStatusLine.configuredCommand(settings: settings) == previous)
        #expect(defaults.bool(forKey: AppStorageKeys.Limits.claudeStatusLineOptOut))
        try resumed.shutdown()
        let optedOut = UsageCLIHookOwner(
            directory: root.appendingPathComponent("owner"), defaults: defaults,
            executable: currentPath)
        try optedOut.resumeOwnedHooks()
        #expect(try ClaudeStatusLine.configuredCommand(settings: settings) == previous)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect(object["sample"] as? Bool == true)
        try optedOut.shutdown()
    }

    @Test func missingTrustedLauncherRejectsExplicitInstallWithoutChangingUserFixture() async throws
    {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        let data = Data(#"{"statusLine":{"type":"command","command":"cat"},"sample":true}"#.utf8)
        try data.write(to: settings)
        let suite = "edith.usage.launcher." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let commands = UsageStatusLineCommands(
            settings: settings, history: root.appendingPathComponent("limits-history.jsonl"),
            defaults: defaults)
        await #expect(throws: (any Error).self) {
            try await commands.execute("usage.statusline.install", payload: Data("{}".utf8))
        }
        #expect(try Data(contentsOf: settings) == data)
        try await commands.shutdown()
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(app: URL) throws -> NSDictionary {
        let contents = app.appendingPathComponent("Contents")
        for directory in ["MacOS", "Resources"] {
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: sourceRoot.appendingPathComponent("Resources/ed-launcher"))
        let resource = contents.appendingPathComponent("Resources/ed-launcher")
        try bytes.write(to: resource)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: resource.path)
        try FileManager.default.createSymbolicLink(
            atPath: contents.appendingPathComponent("MacOS/ed").path,
            withDestinationPath: "../Resources/ed-launcher")
        try writeInfo(
            [
                "CFBundleIdentifier": "com.pulkit.edith.tests." + UUID().uuidString,
                "CFBundlePackageType": "APPL", "CFBundleExecutable": "Edith",
                "CFBundleVersion": "1",
            ], app: app)
        return try context(app: app)
    }

    private func context(app: URL) throws -> NSDictionary {
        let info = try info(app)
        let identifier = try #require(info["CFBundleIdentifier"] as? String)
        let launcher = app.appendingPathComponent("Contents/MacOS/ed")
        let resource = try Data(
            contentsOf: app.appendingPathComponent("Contents/Resources/ed-launcher"))
        return [
            "hostIdentifier": identifier, "recoveryOnly": false,
            "publicLauncher": [
                "version": 1, "hostIdentifier": identifier, "applicationURL": app.absoluteString,
                "launcherURL": launcher.absoluteString, "buildVersion": info["CFBundleVersion"]!,
                "signatureHash": Data(repeating: 1, count: 20).base64EncodedString(),
                "bundleFileID": "1:1", "launcherFileID": "1:2",
                "launcherSHA256": UsageMachinesPeer.hash(resource),
            ],
        ]
    }

    private func info(_ app: URL) throws -> [String: Any] {
        try #require(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                format: nil) as? [String: Any])
    }

    private func writeInfo(_ info: [String: Any], app: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
            to: app.appendingPathComponent("Contents/Info.plist"))
    }
}
