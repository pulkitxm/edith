import Darwin
import EdithHostCore
import ExtensionMarketplace
import Foundation

@main
struct HostLifecycleHarness {
    @MainActor static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 4 else { throw HostWorkerError.rejected }
        let extensionID = arguments[3]
        let fixture = URL(fileURLWithPath: arguments[0])
        let sourceApp = URL(fileURLWithPath: arguments[1])
        let releases = URL(fileURLWithPath: arguments[2])
        let app = fixture.appendingPathComponent("Fixture.app")
        try FileManager.default.copyItem(at: sourceApp, to: app)
        let identifier = "com.pulkit.edith.tests.worker-\(UUID().uuidString)"
        let info = app.appendingPathComponent("Contents/Info.plist")
        var plist =
            try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil)
            as! [String: Any]
        plist["CFBundleIdentifier"] = identifier
        plist["CFBundleName"] = "Extension Fixture"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
            to: info)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw MarketplaceError.invalidSignature }
        let executable = app.appendingPathComponent("Contents/MacOS/Edith")
        let identity = try HostIdentity(identifier: identifier, supportDirectory: fixture)
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        let suite = identity.defaultsSuite
        UserDefaults(suiteName: identity.extensionDefaultsSuite(extensionID))?.set(
            false, forKey: "windowSweatersActive")
        UserDefaults(suiteName: identity.extensionDefaultsSuite(extensionID))?.set(
            false, forKey: "keystrokeHighlightActive")
        guard let defaults = UserDefaults(suiteName: suite) else { throw HostWorkerError.rejected }
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults(suiteName: identity.extensionDefaultsSuite(extensionID))?
                .removePersistentDomain(forName: identity.extensionDefaultsSuite(extensionID))
        }
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: package.id, version: package.version),
                executable: executable)
        }
        do {
            let first = try record(releases, id: extensionID, version: "1.0.0")
            let second = try record(releases, id: extensionID, version: "1.1.0")
            try await install(first, releases: releases, store: store)
            guard sessions.processIdentifiers.isEmpty else { throw HostWorkerError.rejected }
            try await sessions.enable(first)
            guard let oldPID = sessions.processIdentifiers[first.id] else {
                throw HostWorkerError.rejected
            }
            try await sessions.show(id: first.id)
            try await install(second, releases: releases, store: store)
            guard sessions.versions[first.id] == first.version, kill(oldPID, 0) == 0 else {
                throw HostWorkerError.rejected
            }
            try await sessions.applyUpdate(second)
            guard sessions.versions[first.id] == second.version,
                let newPID = sessions.processIdentifiers[first.id], newPID != oldPID,
                kill(oldPID, 0) == -1
            else { throw HostWorkerError.rejected }
            await sessions.shutdown()
            guard kill(newPID, 0) == -1, sessions.enabledIDs.contains(first.id) else {
                throw HostWorkerError.rejected
            }
            await sessions.restore(packages: [second.id: second])
            guard sessions.versions[first.id] == second.version else {
                throw HostWorkerError.rejected
            }
            try await sessions.disable(id: first.id)
            guard sessions.processIdentifiers.isEmpty, sessions.enabledIDs.isEmpty else {
                throw HostWorkerError.rejected
            }
            guard try store.requestRemoval(id: first.id), try store.installedPackages().isEmpty
            else { throw HostWorkerError.rejected }
            print(
                "{\"downloadedBundle\":true,\"nativeWindow\":true,\"updateWithoutAppRestart\":true,\"restoreAfterAppUpdate\":true,\"disabledProcesses\":0,\"removedPayloads\":true}"
            )
        } catch {
            await sessions.shutdown()
            throw error
        }
    }

    private static func record(_ directory: URL, id: String, version: String) throws
        -> ExtensionPackage
    {
        try JSONDecoder().decode(
            ExtensionPackage.self,
            from: Data(
                contentsOf: directory.appendingPathComponent(version).appendingPathComponent(
                    "\(id).json")))
    }

    private static func install(
        _ package: ExtensionPackage, releases: URL, store: ExtensionPackageStore
    ) async throws {
        let installer = ExtensionPackageInstaller(
            store: store,
            download: { _, _ in
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)
                try FileManager.default.copyItem(
                    at: releases.appendingPathComponent(package.version).appendingPathComponent(
                        "\(package.id).zip"), to: temporary)
                return temporary
            },
            verify: { directory in
                for role in ExtensionBundleRuntime.Role.allCases {
                    let bundle = directory.appendingPathComponent("\(role.rawValue).bundle")
                    if FileManager.default.fileExists(atPath: bundle.path) {
                        try ExtensionCodeSignature.verifyDevelopment(bundle)
                    }
                }
            })
        _ = try await installer.install([package], repository: MarketplaceConfiguration.repository)
    }
}
