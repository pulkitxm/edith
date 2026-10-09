import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
        guard arguments.count == 5, ["0", "1"].contains(arguments[4]) else {
            throw HostWorkerError.rejected
        }
        let validateSurface = arguments[4] == "1"
        let extensionID = arguments[3]
        let fixture = URL(fileURLWithPath: arguments[0])
        if extensionID == "studio" {
            setenv(
                "EDITH_TEST_RUNTIME_ROOT", fixture.appendingPathComponent("studio-runtime").path, 1)
        }
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
        if extensionID == "clipboard" {
            UserDefaults(suiteName: identity.extensionDefaultsSuite(extensionID))?.set(
                false, forKey: AppStorageKeys.Clipboard.enabled)
        }
        let companionServer = extensionID == "companion" ? try CompanionFixtureServer() : nil
        defer { companionServer?.stop() }
        if let companionServer {
            try await companionServer.start()
            UserDefaults(suiteName: identity.extensionDefaultsSuite(extensionID))?.set(
                "http://127.0.0.1:\(companionServer.port)",
                forKey: AppStorageKeys.Companion.endpoint)
        }
        if extensionID == "terminal" {
            let terminalDefaults = UserDefaults(
                suiteName: identity.extensionDefaultsSuite(extensionID))
            terminalDefaults?.set("/bin/sh", forKey: "terminalShell")
            terminalDefaults?.set(false, forKey: "terminalLoginShell")
            terminalDefaults?.set("custom", forKey: "terminalStartFolder")
            terminalDefaults?.set(fixture.path, forKey: "terminalCustomFolder")
            terminalDefaults?.set(false, forKey: "terminalConfirmClose")
        }
        guard let defaults = UserDefaults(suiteName: suite) else { throw HostWorkerError.rejected }
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults(suiteName: identifier)?.removePersistentDomain(forName: identifier)
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
        func makeSessions(executable: URL) -> HostExtensionSessions {
            HostExtensionSessions(defaults: UserDefaults(suiteName: suite)!) { package in
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
        }
        var sessions = makeSessions(executable: executable)
        var surfaces = try HostSurfaces(
            identity: identity, entries: HostIndex.bundled(), sessions: sessions)
        surfaces.layouts.update(.home) { $0.tiles = [.init(.ability(extensionID))] }
        guard surfaces.context.activeIDs.isEmpty else { throw HostWorkerError.rejected }
        defer { for handle in logHandles { try? handle.close() } }
        var stage = "installation"
        var terminalChildren: [Int32] = []
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
            guard surfaces.context.activeIDs == [extensionID] else {
                throw HostWorkerError.invalidResponse
            }
            let savedSurface = surfaces.layouts.home
            stage = "window"
            try await sessions.show(id: first.id)
            let opened = try await endpoint.invoke("extension.open")
            guard String(decoding: opened, as: UTF8.self) == "{\"opened\":true}" else {
                throw HostWorkerError.invalidResponse
            }
            try await verifySurfaceContext(
                endpoint, saved: savedSurface, id: extensionID, validateData: validateSurface)
            stage = "initial commands"
            if extensionID == "audioMixer" {
                try await AudioMixerFixture.verify(endpoint)
            } else if extensionID == "latex" {
                try await verifyLaTeX(endpoint, fixture: fixture, seed: true)
            } else if let companionServer {
                try await verifyCompanion(endpoint, server: companionServer)
            } else if extensionID == "terminal" {
                terminalChildren = try await verifyTerminal(endpoint, workerPID: oldPID)
            } else if extensionID == "clipboard" {
                try await verifyClipboard(endpoint, seed: true)
            } else if extensionID == "studio" {
                try await verifyStudio(endpoint, fixture: fixture, seed: true)
            } else if extensionID == "blitztree" {
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
            guard surfaces.context.activeIDs == [extensionID],
                surfaces.layouts.home == savedSurface
            else { throw HostWorkerError.invalidResponse }
            try await verifySurfaceContext(
                endpoint, saved: savedSurface, id: extensionID, validateData: validateSurface)
            stage = "updated commands"
            guard sessions.versions[first.id] == second.version,
                let newPID = sessions.processIdentifiers[first.id], newPID != oldPID,
                kill(oldPID, 0) == -1
            else { throw HostWorkerError.rejected }
            try await requireExited(terminalChildren)
            if extensionID == "audioMixer" {
                try await AudioMixerFixture.verify(endpoint)
            } else if extensionID == "latex" {
                try await verifyLaTeX(endpoint, fixture: fixture, seed: false)
            } else if let companionServer {
                try await verifyCompanion(endpoint, server: companionServer)
            } else if extensionID == "terminal" {
                terminalChildren = try await verifyTerminal(endpoint, workerPID: newPID)
            } else if extensionID == "clipboard" {
                try await verifyClipboard(endpoint, seed: false)
            } else if extensionID == "studio" {
                try await verifyStudio(endpoint, fixture: fixture, seed: false)
            } else if extensionID == "blitztree" {
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
            try await requireExited(terminalChildren)
            guard surfaces.context.activeIDs.isEmpty,
                surfaces.layouts.home == savedSurface
            else { throw HostWorkerError.invalidResponse }
            stage = "replace host application"
            let replacement = fixture.appendingPathComponent("UpdatedFixture.app")
            try FileManager.default.copyItem(at: app, to: replacement)
            let replacementInfo = replacement.appendingPathComponent("Contents/Info.plist")
            plist["CFBundleVersion"] = "2"
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: replacementInfo)
            let replacementSign = Process()
            replacementSign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            replacementSign.arguments = ["--force", "--sign", "-", replacement.path]
            try replacementSign.run()
            replacementSign.waitUntilExit()
            guard replacementSign.terminationStatus == 0 else {
                throw MarketplaceError.invalidSignature
            }
            try FileManager.default.removeItem(at: app)
            sessions = makeSessions(
                executable: replacement.appendingPathComponent("Contents/MacOS/Edith"))
            surfaces = try HostSurfaces(
                identity: identity, entries: HostIndex.bundled(), sessions: sessions)
            guard sessions.processIdentifiers.isEmpty,
                sessions.enabledIDs == [extensionID],
                surfaces.layouts.home == savedSurface
            else { throw HostWorkerError.invalidResponse }
            stage = "restore in replacement host"
            await sessions.restore(packages: [second.id: second])
            guard let restoredPID = sessions.processIdentifiers[first.id], restoredPID != newPID,
                kill(restoredPID, 0) == 0
            else { throw HostWorkerError.rejected }
            try await verifySurfaceContext(
                endpoint, saved: savedSurface, id: extensionID, validateData: validateSurface)
            guard sessions.versions[first.id] == second.version,
                let restoredPID = sessions.processIdentifiers[first.id]
            else {
                throw HostWorkerError.rejected
            }
            if extensionID == "audioMixer" {
                try await AudioMixerFixture.verify(endpoint)
            } else if extensionID == "latex" {
                try await verifyLaTeX(endpoint, fixture: fixture, seed: false)
            } else if let companionServer {
                try await verifyCompanion(endpoint, server: companionServer)
            } else if extensionID == "terminal" {
                terminalChildren = try await verifyTerminal(endpoint, workerPID: restoredPID)
            } else if extensionID == "clipboard" {
                try await verifyClipboard(endpoint, seed: false)
            } else if extensionID == "studio" {
                try await verifyStudio(endpoint, fixture: fixture, seed: false)
            } else if extensionID == "blitztree" {
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
            guard surfaces.context.activeIDs.isEmpty,
                surfaces.layouts.home == savedSurface,
                sessions.processIdentifiers.isEmpty, sessions.enabledIDs.isEmpty
            else {
                throw HostWorkerError.rejected
            }
            if let companionServer {
                let settled = companionServer.requests.count
                try await Task.sleep(for: .seconds(2))
                guard companionServer.requests.count == settled else {
                    throw CompanionFixtureError.failed(
                        "The disabled Companion worker kept contacting its backend.")
                }
            }
            try await requireExited(terminalChildren)
            guard try store.requestRemoval(id: first.id), try store.installedPackages().isEmpty
            else { throw HostWorkerError.rejected }
            guard surfaces.layouts.home == savedSurface,
                surfaces.context.visibleLayout(.home).tiles.isEmpty
            else {
                throw HostWorkerError.invalidResponse
            }
            for handle in logHandles { try handle.close() }
            guard
                try workerLogs.allSatisfy({
                    !(try String(contentsOf: $0, encoding: .utf8)).contains(
                        "is implemented in both")
                })
            else { throw HostWorkerError.invalidResponse }
            print(
                "{\"downloadedBundle\":true,\"nativeWindow\":true,\"updateWithoutAppRestart\":true,\"restoreAfterAppUpdate\":true,\"freshHostSessionRestored\":true,\"disabledProcesses\":0,\"removedPayloads\":true,\"isolatedSupportTypes\":true,\"surfaceLayoutRestored\":true,\"surfaceDataValidated\":\(validateSurface),\"clipboardDataValidated\":\(extensionID == "clipboard"),\"latexDataValidated\":\(extensionID == "latex"),\"companionDataValidated\":\(extensionID == "companion"),\"terminalDataValidated\":\(extensionID == "terminal"),\"studioDataValidated\":\(extensionID == "studio"),\"audioMixerDataValidated\":\(extensionID == "audioMixer")}"
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

    @MainActor private static func verifySurfaceContext(
        _ endpoint: ExtensionPeerEndpoint, saved: SurfaceLayout, id: String, validateData: Bool
    ) async throws {
        let data = try await endpoint.invoke("surface.context")
        let context = try JSONDecoder().decode(SurfaceContextSnapshot.self, from: data)
        guard context.contractVersion == 1, context.activeIDs == [id],
            context.activeVersions[id] != nil, context.home == saved
        else {
            throw HostWorkerError.invalidResponse
        }
        if validateData {
            var tile = SurfaceTile(.ability(id))
            tile.itemLimit = 3
            let request = SurfaceSnapshotRequest(target: .home, tile: tile)
            let data = try await endpoint.invoke(
                "surface.snapshot", payload: request.encoded(providerID: id))
            let snapshot = try SurfaceSnapshot.decode(data, providerID: id)
            guard snapshot.rows.count <= request.tile.itemLimit else {
                throw HostWorkerError.invalidResponse
            }
            do {
                let invalid = SurfaceActionRequest(
                    snapshot: request, actionID: "invalid-synthetic-action")
                _ = try await endpoint.invoke(
                    "surface.perform", payload: invalid.encoded(providerID: id))
                throw HostWorkerError.invalidResponse
            } catch HostWorkerError.invalidResponse { throw HostWorkerError.invalidResponse } catch
            {}
        }
    }

    @MainActor private static func verifyLaTeX(
        _ endpoint: ExtensionPeerEndpoint, fixture: URL, seed: Bool
    ) async throws {
        _ = try await endpoint.invoke("extension.open")
        let projectID = "20000000-0000-0000-0000-000000000001"
        let source = fixture.appendingPathComponent("synthetic-paper.tex")
        let original =
            "\\documentclass{article}\n\\begin{document}Synthetic original\\end{document}\n"
        let draft =
            "\\documentclass{article}\n\\begin{document}Synthetic unsaved draft\\end{document}\n"
        if seed {
            try original.write(to: source, atomically: true, encoding: .utf8)
            let empty = try await endpoint.invoke("latex.projects")
            guard (try JSONSerialization.jsonObject(with: empty) as? [Any])?.isEmpty == true else {
                throw HostWorkerError.invalidResponse
            }
            let payload = try JSONSerialization.data(withJSONObject: [
                "id": projectID, "name": "Synthetic paper", "location": "disk",
                "compiler": "tectonic", "sourcePath": source.path, "repository": "",
                "baseBranch": "",
            ])
            _ = try await endpoint.invoke("latex.addProject", payload: payload)
            _ = try await endpoint.invoke(
                "latex.openProject", payload: JSONEncoder().encode(projectID))
            let document = try await endpoint.invoke("latex.document")
            guard let value = try JSONSerialization.jsonObject(with: document) as? [String: Any],
                value["text"] as? String == original,
                let revision = value["revision"] as? String, !revision.isEmpty
            else { throw LaTeXFixtureError.invalidData }
            _ = try await endpoint.invoke(
                "latex.setDraft",
                payload: JSONSerialization.data(withJSONObject: [
                    "projectID": projectID, "revision": revision, "text": draft,
                ]))
        }
        let projects = try await endpoint.invoke("latex.projects")
        guard let library = try JSONSerialization.jsonObject(with: projects) as? [[String: Any]],
            library.count == 1, library.first?["id"] as? String == projectID
        else { throw LaTeXFixtureError.invalidData }
        let document = try await endpoint.invoke("latex.document")
        guard let value = try JSONSerialization.jsonObject(with: document) as? [String: Any],
            value["text"] as? String == draft,
            value["revision"] as? String != nil,
            try String(contentsOf: source, encoding: .utf8) == original
        else { throw LaTeXFixtureError.invalidData }
        var ready = false
        for _ in 0..<100 {
            let status = try await endpoint.invoke("latex.editorStatus")
            let value = try JSONSerialization.jsonObject(with: status) as? [String: Any]
            guard value?["dirty"] as? Bool == true, value?["toolProcesses"] as? Int == 0 else {
                throw HostWorkerError.invalidResponse
            }
            if value?["ready"] as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { throw LaTeXFixtureError.invalidData }
        var tile = SurfaceTile(.ability("latex"))
        tile.itemLimit = 1
        tile.sourceIDs = [projectID]
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let data = try await endpoint.invoke(
            "surface.snapshot", payload: request.encoded(providerID: "latex"))
        let snapshot = try SurfaceSnapshot.decode(data, providerID: "latex")
        guard snapshot.rows.count == 1, snapshot.sources.count == 1,
            snapshot.rows.first?.title == "Synthetic paper",
            snapshot.rows.first?.actions.isEmpty == true
        else { throw LaTeXFixtureError.invalidData }
    }

    @MainActor private static func verifyClipboard(_ endpoint: ExtensionPeerEndpoint, seed: Bool)
        async throws
    {
        let statusData = try await endpoint.invoke("clipboard.captureStatus")
        let status = try JSONSerialization.jsonObject(with: statusData) as? [String: Any]
        guard status?["enabled"] as? Bool == false, status?["monitoring"] as? Bool == false else {
            throw NSError(
                domain: "ClipboardFixture", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Capture monitoring was enabled in the synthetic fixture."
                ])
        }
        let fixtures = [
            ("10000000-0000-0000-0000-000000000001", "synthetic native note one"),
            ("10000000-0000-0000-0000-000000000002", "synthetic native note two"),
            ("10000000-0000-0000-0000-000000000003", "https://example.com/mock-clipboard"),
        ]
        let imageID = "10000000-0000-0000-0000-000000000004"
        let image = try clipboardFixtureImage()
        let query = try JSONSerialization.data(withJSONObject: [
            "offset": 0, "limit": 10, "recentlyCreated": false,
        ])
        if seed {
            let empty = try await endpoint.invoke("clipboard.snapshot", payload: query)
            guard
                (try JSONSerialization.jsonObject(with: empty) as? [String: Any])?["total"] as? Int
                    == 0
            else {
                throw NSError(
                    domain: "ClipboardFixture", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "New clipboard archive was not empty."])
            }
            for (id, text) in fixtures {
                let payload = try JSONSerialization.data(withJSONObject: [
                    "id": id, "data": Data(text.utf8).base64EncodedString(),
                    "types": ["public.text"],
                    "ext": "txt", "preview": text, "sourceApp": "Mock Notes",
                    "sourceBundleID": "example.mock.notes",
                    "capturedAt": Date().timeIntervalSinceReferenceDate,
                ])
                let output = try await endpoint.invoke("clipboard.capture", payload: payload)
                guard
                    (try JSONSerialization.jsonObject(with: output) as? [String: Any])?["changed"]
                        as? Int == 1
                else {
                    throw NSError(
                        domain: "ClipboardFixture", code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Synthetic clipboard capture was not acknowledged."
                        ])
                }
            }
            _ = try await endpoint.invoke(
                "clipboard.capture",
                payload: JSONSerialization.data(withJSONObject: [
                    "id": imageID, "data": image.base64EncodedString(), "types": ["public.png"],
                    "ext": "png", "preview": "synthetic native image", "sourceApp": "Mock Camera",
                    "sourceBundleID": "example.mock.camera",
                    "capturedAt": Date().timeIntervalSinceReferenceDate,
                ]))
            _ = try await endpoint.invoke(
                "clipboard.mutate",
                payload: JSONSerialization.data(withJSONObject: [
                    "kind": "pin", "ids": [fixtures[0].0],
                    "copiedAt": Date().timeIntervalSinceReferenceDate,
                ]))
        }
        let storedData = try await endpoint.invoke("clipboard.snapshot", payload: query)
        guard let stored = try JSONSerialization.jsonObject(with: storedData) as? [String: Any],
            stored["total"] as? Int == 4, let entries = stored["entries"] as? [[String: Any]],
            Set(entries.compactMap { $0["preview"] as? String })
                == Set(fixtures.map(\.1) + ["synthetic native image"]),
            entries.first(where: { $0["id"] as? String == fixtures[0].0 })?["pinned"] as? Bool
                == true
        else {
            throw NSError(
                domain: "ClipboardFixture", code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Synthetic clipboard history or pin was not retained."
                ])
        }
        let copied = try await endpoint.invoke(
            "clipboard.copyPayload",
            payload: JSONSerialization.data(withJSONObject: [
                "id": fixtures[0].0, "plainTextOnly": false,
            ]))
        guard let payload = try JSONSerialization.jsonObject(with: copied) as? [String: Any],
            payload["data"] as? String == Data(fixtures[0].1.utf8).base64EncodedString(),
            payload["text"] as? String == fixtures[0].1
        else {
            throw NSError(
                domain: "ClipboardFixture", code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: "Synthetic clipboard payload was not retained."
                ])
        }
        var tile = SurfaceTile(.ability("clipboard")); tile.sourceIDs = ["text"];
        tile.itemLimit = 1; tile.showDetails = false
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        let data = try await endpoint.invoke(
            "surface.snapshot", payload: request.encoded(providerID: "clipboard"))
        let snapshot = try SurfaceSnapshot.decode(data, providerID: "clipboard")
        guard snapshot.rows.count == 1, snapshot.rows[0].id == fixtures[0].0,
            snapshot.rows[0].sourceID == "text", snapshot.rows[0].detail.isEmpty,
            snapshot.rows[0].value == "Pinned", snapshot.rows[0].actions.count == 3
        else {
            throw NSError(
                domain: "ClipboardFixture", code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Clipboard category, item limit, or opaque actions were invalid."
                ])
        }
        var images = SurfaceTile(.ability("clipboard")); images.sourceIDs = ["image"];
        images.itemLimit = 1
        var imageSnapshot = SurfaceSnapshot(providerID: "clipboard")
        for _ in 0..<6 {
            imageSnapshot = try SurfaceSnapshot.decode(
                try await endpoint.invoke(
                    "surface.snapshot",
                    payload: SurfaceSnapshotRequest(target: .home, tile: images).encoded(
                        providerID: "clipboard")), providerID: "clipboard")
            if imageSnapshot.rows.first?.thumbnail != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard imageSnapshot.rows.count == 1, imageSnapshot.rows[0].id == imageID,
            let preview = imageSnapshot.rows[0].thumbnail, preview.data.count <= 131_072
        else {
            throw NSError(
                domain: "ClipboardFixture", code: 8,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Synthetic image preview was unavailable: rows \(imageSnapshot.rows.count), preview \(imageSnapshot.rows.first?.thumbnail != nil)."
                ])
        }
        try preview.validate()
        let rawPreview = try await endpoint.invoke(
            "clipboard.thumbnail",
            payload: JSONSerialization.data(withJSONObject: [
                "id": UUID().uuidString, "entryID": imageID,
            ]))
        guard let raw = try JSONSerialization.jsonObject(with: rawPreview) as? [String: Any],
            let encodedPreview = raw["data"] as? String,
            let previewBytes = Data(base64Encoded: encodedPreview), !previewBytes.isEmpty
        else {
            throw NSError(
                domain: "ClipboardFixture", code: 9,
                userInfo: [
                    NSLocalizedDescriptionKey: "The loaded clipboard renderer returned no image."
                ])
        }
        try SurfaceThumbnail(data: previewBytes).validate()
        images.hiddenFields = ["previews"]
        let hiddenImage = try SurfaceSnapshot.decode(
            try await endpoint.invoke(
                "surface.snapshot",
                payload: SurfaceSnapshotRequest(target: .home, tile: images).encoded(
                    providerID: "clipboard")), providerID: "clipboard")
        guard hiddenImage.rows.count == 1, hiddenImage.rows[0].thumbnail == nil else {
            throw HostWorkerError.invalidResponse
        }
        tile.showActions = false
        let hidden = SurfaceActionRequest(
            snapshot: .init(target: .notch, tile: tile), actionID: "delete/" + fixtures[0].0)
        do {
            _ = try await endpoint.invoke(
                "surface.perform", payload: hidden.encoded(providerID: "clipboard"))
            throw NSError(
                domain: "ClipboardFixture", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Hidden clipboard deletion was accepted."])
        } catch is ExtensionPeerError {}
    }

    private static func clipboardFixtureImage() throws -> Data {
        guard
            let context = CGContext(
                data: nil, width: 64, height: 32, bitsPerComponent: 8,
                bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw HostWorkerError.invalidResponse }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let data = NSMutableData()
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { throw HostWorkerError.invalidResponse }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw HostWorkerError.invalidResponse }
        return data as Data
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

    @MainActor private static func verifyTerminal(
        _ endpoint: ExtensionPeerEndpoint, workerPID: Int32
    ) async throws -> [Int32] {
        func object(_ command: String, _ input: [String: Any] = [:]) async throws -> Any {
            let data = try await endpoint.invoke(
                command, payload: JSONSerialization.data(withJSONObject: input), timeout: 5)
            return try JSONSerialization.jsonObject(with: data)
        }
        func settled(including id: String) async throws -> (Int, [Int32]) {
            let deadline = Date().addingTimeInterval(20)
            while true {
                let status = try await object("terminal.status") as? [String: Any]
                let listed = try await object("terminal.sessions") as? [[String: Any]] ?? []
                let children = childProcesses(of: workerPID)
                if let count = status?["sessions"] as? Int, count == listed.count,
                    status?["running"] as? Int == count,
                    listed.contains(where: { $0["id"] as? String == id }),
                    children.count >= count
                {
                    return (count, children)
                }
                guard Date() < deadline else { throw HostWorkerError.invalidResponse }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        let opened = try await object("terminal.open") as? [String: Any]
        guard opened?["opened"] as? Bool == true, let id = opened?["id"] as? String else {
            throw HostWorkerError.invalidResponse
        }
        _ = try await settled(including: id)
        let selected = try await object("terminal.select", ["id": id]) as? [[String: Any]]
        guard
            selected?.contains(where: {
                $0["id"] as? String == id && $0["selected"] as? Bool == true
            }) == true
        else { throw HostWorkerError.invalidResponse }
        var tile = SurfaceTile(.ability("terminal"))
        tile.itemLimit = 20
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let created = try SurfaceSnapshot.decode(
            try await endpoint.invoke(
                "surface.perform",
                payload: SurfaceActionRequest(snapshot: request, actionID: "new").encoded(
                    providerID: "terminal")), providerID: "terminal")
        guard let added = created.rows.last?.id, added != id,
            created.rows.allSatisfy({ $0.title.utf8.count <= 512 })
        else { throw HostWorkerError.invalidResponse }
        let (count, children) = try await settled(including: added)
        let broadcast =
            try await object("terminal.broadcast", ["command": "true"]) as? [String: Any]
        guard broadcast?["sent"] as? Int == count, broadcast?["unavailable"] as? Int == 0 else {
            throw HostWorkerError.invalidResponse
        }
        for (command, input) in [
            ("terminal.broadcast", ["command": " "]), ("terminal.select", ["id": "synthetic"]),
            ("terminal.status", ["unexpected": true]), ("terminal.unknown", [:]),
        ] as [(String, [String: Any])] {
            do {
                _ = try await object(command, input)
                throw HostWorkerError.invalidResponse
            } catch HostWorkerError.invalidResponse {
                throw HostWorkerError.invalidResponse
            } catch {}
        }
        return children
    }

    private static func childProcesses(of pid: Int32) -> [Int32] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            Int32($0.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func requireExited(_ pids: [Int32]) async throws {
        let deadline = Date().addingTimeInterval(10)
        while pids.contains(where: { kill($0, 0) == 0 }) {
            guard Date() < deadline else { throw HostWorkerError.rejected }
            try await Task.sleep(for: .milliseconds(100))
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

private enum LaTeXFixtureError: Error {
    case invalidData
    case editorNotReady
}
