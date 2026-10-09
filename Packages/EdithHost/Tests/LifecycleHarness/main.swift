import Darwin
import EdithHostCore
import EdithExtensionSupport
import LocalAuthentication
import Security
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
        let endpoint = try ExtensionPeerEndpoint(
            namespace: identifier, owner: extensionID,
            directory: identity.root.appendingPathComponent("ExtensionState/Commands"))
        defer {
            if extensionID == "jev" {
                let context = LAContext()
                context.interactionNotAllowed = true
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: identifier + ".extensions.jev",
                    kSecAttrAccount as String: "typesafe-api-key",
                    kSecUseAuthenticationContext as String: context,
                ]
                _ = SecItemDelete(query as CFDictionary)
            }
        }
        var workerLogs: [URL] = []
        var logHandles: [FileHandle] = []
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            let log = fixture.appendingPathComponent("worker-" + UUID().uuidString + ".log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try! FileHandle(forWritingTo: log)
            workerLogs.append(log)
            logHandles.append(handle)
            return
                HostWorker(
                    configuration: HostWorkerConfiguration(
                        identity: identity, extensionID: package.id, version: package.version),
                    executable: executable, errorOutput: handle)
        }
        defer { for handle in logHandles { try? handle.close() } }
        var stage = "installation"
        do {
            let first = try record(releases, id: extensionID, version: "1.0.0")
            let second = try record(releases, id: extensionID, version: "1.1.0")
            try await install(first, releases: releases, store: store)
            guard sessions.processIdentifiers.isEmpty else { throw HostWorkerError.rejected }
            stage = "enable"
            try await sessions.enable(first)
            guard let oldPID = sessions.processIdentifiers[first.id] else {
                throw HostWorkerError.rejected
            }
            stage = "window"
            try await sessions.show(id: first.id)
            let opened = try await endpoint.invoke("extension.open")
            guard String(decoding: opened, as: UTF8.self) == "{\"opened\":true}" else {
                throw HostWorkerError.invalidResponse
            }
            stage = "initial commands"
            if extensionID == "blitztree" {
                try await verifyBlitzTree(endpoint, fixture: fixture)
            } else if extensionID == "appMaintenance" {
                try await verifyMaintenance(endpoint)
            } else if extensionID == "cleaner" {
                try await verifyCleaner(endpoint)
            } else if extensionID == "timeLapse" {
                try await verifyRecording(endpoint)
            } else if extensionID == "system" {
                try await verifySystem(endpoint)
            } else if extensionID == "jev" {
                try await verify(
                    endpoint, command: "jev.status", input: ["probe": false], field: "hasSavedKey",
                    expected: false)
                try await verify(
                    endpoint, command: "jev.key.set", input: ["key": "synthetic-fixture-key"],
                    field: "hasSavedKey", expected: true)
            } else if extensionID == "presenter" {
                try await verify(
                    endpoint, command: "presenter.start", input: [:], field: "active",
                    expected: true)
            }
            try await install(second, releases: releases, store: store)
            guard sessions.versions[first.id] == first.version, kill(oldPID, 0) == 0 else {
                throw HostWorkerError.rejected
            }
            stage = "update"
            try await sessions.applyUpdate(second)
            stage = "updated commands"
            guard sessions.versions[first.id] == second.version,
                let newPID = sessions.processIdentifiers[first.id], newPID != oldPID,
                kill(oldPID, 0) == -1
            else { throw HostWorkerError.rejected }
            if extensionID == "blitztree" {
                try await verifyBlitzTree(endpoint, fixture: fixture)
            } else if extensionID == "appMaintenance" {
                try await verifyMaintenance(endpoint)
            } else if extensionID == "cleaner" {
                try await verifyCleaner(endpoint)
            } else if extensionID == "timeLapse" {
                try await verifyRecording(endpoint)
            } else if extensionID == "system" {
                try await verifySystem(endpoint)
            } else if extensionID == "jev" {
                try await verify(
                    endpoint, command: "jev.status", input: ["probe": false], field: "hasSavedKey",
                    expected: true)
            } else if extensionID == "presenter" {
                try await verify(
                    endpoint, command: "presenter.status", input: [:], field: "active",
                    expected: true)
            }
            await sessions.shutdown()
            guard kill(newPID, 0) == -1, sessions.enabledIDs.contains(first.id) else {
                throw HostWorkerError.rejected
            }
            stage = "restore"
            await sessions.restore(packages: [second.id: second])
            guard sessions.versions[first.id] == second.version else {
                throw HostWorkerError.rejected
            }
            if extensionID == "blitztree" {
                try await verifyBlitzTree(endpoint, fixture: fixture)
            } else if extensionID == "appMaintenance" {
                try await verifyMaintenance(endpoint)
            } else if extensionID == "cleaner" {
                try await verifyCleaner(endpoint)
            } else if extensionID == "timeLapse" {
                try await verifyRecording(endpoint)
            } else if extensionID == "system" {
                try await verifySystem(endpoint)
            } else if extensionID == "jev" {
                try await verify(
                    endpoint, command: "jev.status", input: ["probe": false], field: "hasSavedKey",
                    expected: true)
                try await verify(
                    endpoint, command: "jev.key.set", input: ["key": NSNull()],
                    field: "hasSavedKey", expected: false)
            } else if extensionID == "presenter" {
                try await verify(
                    endpoint, command: "presenter.status", input: [:], field: "active",
                    expected: true)
                try await verify(
                    endpoint, command: "presenter.stop", input: [:], field: "active",
                    expected: false)
                let state = ExtensionSharedState(
                    root: identity.root.appendingPathComponent("ExtensionState"),
                    namespace: identifier)
                guard state.values(for: "presenter")["active"] == "0" else {
                    throw HostWorkerError.rejected
                }
            }
            stage = "disable"
            try await sessions.disable(id: first.id)
            guard sessions.processIdentifiers.isEmpty, sessions.enabledIDs.isEmpty else {
                throw HostWorkerError.rejected
            }
            guard try store.requestRemoval(id: first.id), try store.installedPackages().isEmpty
            else { throw HostWorkerError.rejected }
            for handle in logHandles { try handle.close() }
            guard
                try workerLogs.allSatisfy({
                    !(try String(contentsOf: $0, encoding: .utf8)).contains(
                        "is implemented in both")
                })
            else { throw HostWorkerError.invalidResponse }
            print(
                "{\"downloadedBundle\":true,\"nativeWindow\":true,\"updateWithoutAppRestart\":true,\"restoreAfterAppUpdate\":true,\"disabledProcesses\":0,\"removedPayloads\":true,\"isolatedSupportTypes\":true}"
            )
        } catch {
            if extensionID == "jev" {
                _ = try? await endpoint.invoke(
                    "jev.key.set", payload: Data("{\"key\":null}".utf8), timeout: 2)
            }
            await sessions.shutdown()
            for handle in logHandles { try? handle.close() }
            let logs = workerLogs.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                .joined(separator: "\n")
            throw NSError(
                domain: "ExtensionFixture", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(extensionID) failed during \(stage): \(error). \(logs)"
                ])

        }
    }

    private static func verifyBlitzTree(_ endpoint: ExtensionPeerEndpoint, fixture: URL)
        async throws
    {
        let root = fixture.appendingPathComponent("synthetic-scan", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sample.bin")
        try Data(repeating: 42, count: 4_096).write(to: file)
        let output = try await endpoint.invoke(
            "blitztree.scan", payload: JSONSerialization.data(withJSONObject: ["path": root.path]))
        guard let preview = try JSONSerialization.jsonObject(with: output) as? [String: Any],
            preview["working"] as? Bool == false,
            let token = preview["previewToken"] as? String, UUID(uuidString: token) != nil,
            let report = preview["report"] as? [String: Any],
            let summary = report["summary"] as? [String: Any], summary["fileCount"] as? Int == 1,
            let inventory = (report["report"] as? [String: Any])?["inventory"] as? [String: Any],
            let entry = (inventory["largestChildren"] as? [[String: Any]])?.first,
            let path = entry["path"] as? String
        else { throw HostWorkerError.invalidResponse }
        for confirmed in [false, true] {
            do {
                _ = try await endpoint.invoke(
                    "blitztree.trash",
                    payload: JSONSerialization.data(withJSONObject: [
                        "confirmed": confirmed, "previewToken": UUID().uuidString, "path": path,
                    ]))
                throw HostWorkerError.invalidResponse
            } catch is ExtensionPeerError {}
        }
        guard try Data(contentsOf: file) == Data(repeating: 42, count: 4_096) else {
            throw HostWorkerError.invalidResponse
        }
    }

    private static func verifyMaintenance(_ endpoint: ExtensionPeerEndpoint) async throws {
        try await verify(
            endpoint, command: "maintenance.status", input: [:], field: "enabled", expected: true)
        let data = try await endpoint.invoke("maintenance.preview")
        guard let preview = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = preview["previewToken"] as? String, UUID(uuidString: token) != nil
        else { throw HostWorkerError.invalidResponse }
        for command in ["maintenance.remove", "maintenance.update", "maintenance.install"] {
            do {
                _ = try await endpoint.invoke(command, payload: Data("{\"confirmed\":false}".utf8))
                throw HostWorkerError.invalidResponse
            } catch is ExtensionPeerError {}
        }
    }

    @MainActor private static func verifyCleaner(_ endpoint: ExtensionPeerEndpoint) async throws {
        try await verify(
            endpoint, command: "cleaner.status", input: [:], field: "working", expected: false)
        let preview = try await endpoint.invoke("cleaner.preview", timeout: 5)
        let result = try JSONSerialization.jsonObject(with: preview) as? [String: Any]
        guard let categories = result?["categories"] as? [Any], categories.isEmpty,
            let token = result?["previewToken"] as? String, UUID(uuidString: token) != nil
        else { throw HostWorkerError.rejected }
        for confirmed in [false, true] {
            do {
                _ = try await endpoint.invoke(
                    "cleaner.clean",
                    payload: JSONSerialization.data(
                        withJSONObject: [
                            "confirmed": confirmed, "previewToken": "expired-fixture-preview",
                        ]), timeout: 5)
                throw HostWorkerError.rejected
            } catch ExtensionPeerError.rejected {}
        }
    }

    @MainActor private static func verifyRecording(_ endpoint: ExtensionPeerEndpoint) async throws {
        try await verify(
            endpoint, command: "recording.status", input: [:], field: "recording", expected: false)
        try await verify(
            endpoint, command: "recording.stop", input: [:], field: "recording", expected: false)
        let data = try await endpoint.invoke("recording.list", payload: Data("{}".utf8), timeout: 5)
        guard let recordings = try JSONSerialization.jsonObject(with: data) as? [Any],
            recordings.isEmpty
        else { throw HostWorkerError.rejected }
    }

    @MainActor private static func verifySystem(_ endpoint: ExtensionPeerEndpoint) async throws {
        let data = try await endpoint.invoke("apps.list", payload: Data("{}".utf8), timeout: 5)
        guard let apps = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            apps.allSatisfy({ ($0["pid"] as? Int ?? 0) > 0 && $0["name"] is String })
        else { throw HostWorkerError.rejected }
        do {
            _ = try await endpoint.invoke("apps.quit", payload: Data("{}".utf8), timeout: 5)
            throw HostWorkerError.rejected
        } catch ExtensionPeerError.rejected {
        }
    }

    @MainActor private static func verify(
        _ endpoint: ExtensionPeerEndpoint, command: String, input: [String: Any], field: String,
        expected: Bool
    ) async throws {
        let data = try await endpoint.invoke(
            command, payload: JSONSerialization.data(withJSONObject: input), timeout: 5)
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if field == "hasSavedKey" {
            guard result?["state"] as? String == (expected ? "ready" : "notConfigured") else {
                throw HostWorkerError.rejected
            }
        } else {
            guard result?[field] as? Bool == expected else { throw HostWorkerError.rejected }
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
