import EdithKit
import Foundation
import Testing

@testable import EdithCLI

@Suite struct CLIInProcessWorkTests {
    @Test func toolsInstallDoesTheInstallItselfRatherThanAskingTheApp() async throws {
        await CLIProbe.inWorld { world in
            world.helperRunning(false)
            CLIEnvironment.executableNamed = { _ in nil }
            CLIEnvironment.installTool = { _, log in
                log("Downloading yt-dlp")
                return "2026.07.04"
            }
            let result = await CLIProbe.capture(["tools", "install", "yt-dlp", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["installed"] as? Bool == true)
            #expect(result.object?["version"] as? String == "2026.07.04")
            #expect(world.postedNames().isEmpty)
        }
    }

    @Test func toolsInstallReportsTheManualInstructionWhenItFails() async throws {
        await CLIProbe.inWorld { _ in
            CLIEnvironment.executableNamed = { _ in nil }
            CLIEnvironment.installTool = { _, _ in
                throw ToolInstallFailure.noPackageManager("Claude Code")
            }
            let result = await CLIProbe.capture(["tools", "install", "claude"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("Neither Homebrew nor npm"))
            #expect(result.stderr.contains("brew install"))
            #expect(result.stdout.isEmpty)
        }
    }

    @Test func downloadCancelReportsWhenNoAppWasNotified() async throws {
        await CLIProbe.inWorld { _ in
            CLIEnvironment.isMainAppRunning = { false }
            let result = await CLIProbe.capture(["download", "cancel", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["appRunning"] as? Bool == false)
            #expect(result.object?["appNotified"] as? Bool == false)
        }
    }

    @Test func downloadCommandsShareLifecycleStateAndStableJSON() async throws {
        await CLIProbe.inWorld { world in
            let added = await CLIProbe.capture([
                "download", "add", "https://youtu.be/one", "https://youtu.be/two", "--json",
            ])
            #expect(added.code == 0)
            #expect(added.array?.count == 2)
            #expect((added.array?.first as? [String: Any])?["id"] as? String != nil)
            let active = await CLIProbe.capture(["download", "ls", "--active", "--json"])
            let activeRows = active.array as? [[String: Any]]
            let allRows =
                (await CLIProbe.capture(["download", "ls", "--json"])).array
                as? [[String: Any]]
            #expect(activeRows?.map { $0["index"] as? Int } == allRows?.map { $0["index"] as? Int })

            let status = await CLIProbe.capture(["download", "status", "--json"])
            #expect(status.object?["total"] as? Int == 2)
            #expect(status.object?["queued"] as? Int == 2)
            let cancelled = await CLIProbe.capture(["download", "cancel", "--json"])
            #expect(cancelled.object?["cancelled"] as? Int == 2)
            #expect((cancelled.object?["records"] as? [[String: Any]])?.count == 2)
            let afterCancel = await CLIProbe.capture(["download", "status", "--json"])
            #expect(afterCancel.object?["interrupted"] as? Int == 2)

            let retried = await CLIProbe.capture(["download", "retry", "1", "--json"])
            #expect(retried.object?["retried"] as? Int == 1)
            #expect(world.postedNames().contains(IPC.Name.downloadQueueChanged.rawValue))
        }
    }

    @Test func downloadCancelTargetsOneRecordAndPostsItsStableIdentity() async {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            let first = await CLIProbe.capture([
                "download", "add", "https://youtu.be/one", "--json",
            ])
            _ = await CLIProbe.capture(["download", "add", "https://youtu.be/two", "--json"])
            let id = (first.array?.first as? [String: Any])?["id"] as? String
            let recordsBefore = DownloadQueue.load(from: CLIEnvironment.downloadQueueFile)
            let targetIndex = recordsBefore.firstIndex { $0.id.uuidString == id }.map { $0 + 1 }

            let result = await CLIProbe.capture([
                "download", "cancel", String(targetIndex ?? 0), "--json",
            ])
            let records = result.object?["records"] as? [[String: Any]]
            #expect(result.code == 0)
            #expect(result.object?["cancelled"] as? Int == 1)
            #expect(result.object?["appNotified"] as? Bool == true)
            #expect(records?.first?["id"] as? String == id)
            #expect(
                world.postedPayloads(for: IPC.Name.requestDownloadCancel).last?["id"] as? String
                    == id)
            let recordsAfter = DownloadQueue.load(from: CLIEnvironment.downloadQueueFile)
            #expect(recordsAfter.first { $0.id.uuidString == id }?.state == "interrupted")
            #expect(recordsAfter.first { $0.id.uuidString != id }?.state == "queued")
        }
    }

    @Test func filteredAndAddedRowsKeepTheirFullQueueIndexes() async throws {
        try await CLIProbe.inWorld { _ in
            try DownloadQueue.save(
                [
                    DownloadRecord(
                        url: URL(string: "https://youtu.be/done")!, status: .done("done.m4a"),
                        outputFilename: nil, createdAt: .distantFuture, kind: .audio)
                ], to: CLIEnvironment.downloadQueueFile)
            let added = await CLIProbe.capture([
                "download", "add", "https://youtu.be/active", "--json",
            ])
            let active = await CLIProbe.capture(["download", "ls", "--active", "--json"])
            let addedRow = added.array?.first as? [String: Any]
            let activeRow = active.array?.first as? [String: Any]

            #expect(addedRow?["index"] as? Int == 2)
            #expect(activeRow?["index"] as? Int == 2)
            #expect(activeRow?["id"] as? String == addedRow?["id"] as? String)
        }
    }

    @Test func downloadHistoryMutationsPreviewUntilConfirmed() async throws {
        try await CLIProbe.inWorld { _ in
            let queue = CLIEnvironment.downloadQueueFile
            try DownloadQueue.save(
                [
                    DownloadRecord(
                        url: URL(string: "https://youtu.be/one")!, status: .done("one.m4a"),
                        outputFilename: nil, createdAt: Date(), kind: .audio)
                ], to: queue)

            let removePreview = await CLIProbe.capture(["download", "rm", "1", "--json"])
            #expect(removePreview.object?["preview"] as? Bool == true)
            #expect(removePreview.object?["removed"] as? Int == 0)
            #expect(DownloadQueue.load(from: queue).count == 1)
            let remove = await CLIProbe.capture(["download", "rm", "1", "--yes", "--json"])
            #expect(remove.object?["preview"] as? Bool == false)
            #expect(remove.object?["removed"] as? Int == 1)

            _ = await CLIProbe.capture(["download", "add", "https://youtu.be/two", "--json"])
            _ = await CLIProbe.capture(["download", "cancel", "--json"])
            let clearPreview = await CLIProbe.capture([
                "download", "clear", "--json",
            ])
            #expect(clearPreview.object?["wouldRemove"] as? Int == 1)
            #expect(DownloadQueue.load(from: queue).count == 1)
            let clear = await CLIProbe.capture([
                "download", "clear", "--yes", "--json",
            ])
            #expect(clear.object?["removed"] as? Int == 1)
            #expect(DownloadQueue.load(from: queue).isEmpty)
        }
    }

    @Test func toolVersionsAreRememberedUntilTheBinaryChanges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-toolcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = ToolVersionCache.storeURL
        ToolVersionCache.storeURL = dir.appendingPathComponent("versions.json")
        defer { ToolVersionCache.storeURL = previous }

        let binary = dir.appendingPathComponent("fake-tool")
        try "one".write(to: binary, atomically: true, encoding: .utf8)
        #expect(ToolVersionCache.cached(for: binary) == nil)
        ToolVersionCache.remember("1.0.0", for: binary)
        #expect(ToolVersionCache.cached(for: binary) == "1.0.0")

        try "a longer body that changes the size".write(
            to: binary, atomically: true, encoding: .utf8)
        #expect(ToolVersionCache.cached(for: binary) == nil)
    }

    @Test func toolVersionsFollowSymlinkTargets() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-toolcache-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = ToolVersionCache.storeURL
        ToolVersionCache.storeURL = dir.appendingPathComponent("versions.json")
        defer { ToolVersionCache.storeURL = previous }

        let target = dir.appendingPathComponent("versions/tool")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "version one".write(to: target, atomically: true, encoding: .utf8)
        let executable = dir.appendingPathComponent("tool")
        try FileManager.default.createSymbolicLink(
            atPath: executable.path, withDestinationPath: "versions/tool")

        #expect(ToolVersionCache.stamp(for: executable)?.size == 11)
        ToolVersionCache.remember("1.0.0", for: executable)
        #expect(ToolVersionCache.cached(for: executable) == "1.0.0")

        try "version two is longer".write(to: target, atomically: true, encoding: .utf8)
        #expect(ToolVersionCache.cached(for: executable) == nil)
    }

    @Test func toolsListReprobesUpdatedSymlinkTargets() async throws {
        try await CLIProbe.inWorld { world in
            let previous = ToolVersionCache.storeURL
            ToolVersionCache.storeURL = world.sandbox.appendingPathComponent("versions.json")
            defer { ToolVersionCache.storeURL = previous }

            let target = world.sandbox.appendingPathComponent("versions/codex")
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho 'codex-cli 1.0.0'\n".utf8).write(to: target)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: target.path)
            let executable = world.sandbox.appendingPathComponent("codex")
            try FileManager.default.createSymbolicLink(
                atPath: executable.path, withDestinationPath: "versions/codex")
            CLIEnvironment.executableNamed = { $0 == "codex" ? executable : nil }

            let first = await CLIProbe.capture(["tools", "ls", "--json"])
            let firstCodex = (first.array as? [[String: Any]])?.first {
                $0["id"] as? String == "codex"
            }
            #expect(firstCodex?["version"] as? String == "codex-cli 1.0.0")

            try Data("#!/bin/sh\necho 'codex-cli 2.0.0 updated'\n".utf8).write(
                to: target, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: target.path)
            let second = await CLIProbe.capture(["tools", "ls", "--json"])
            let secondCodex = (second.array as? [[String: Any]])?.first {
                $0["id"] as? String == "codex"
            }
            #expect(secondCodex?["version"] as? String == "codex-cli 2.0.0 updated")
        }
    }

    @Test func toolVersionsDetectMetadataPreservingExecutableReplacement() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-toolcache-replacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = ToolVersionCache.storeURL
        ToolVersionCache.storeURL = dir.appendingPathComponent("versions.json")
        defer { ToolVersionCache.storeURL = previous }

        let executable = dir.appendingPathComponent("tool")
        try "version one".write(to: executable, atomically: true, encoding: .utf8)
        let modified = try #require(
            FileManager.default.attributesOfItem(atPath: executable.path)[.modificationDate]
                as? Date)
        ToolVersionCache.remember("1.0.0", for: executable)

        try "version two".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: executable.path)
        #expect(ToolVersionCache.cached(for: executable) == nil)
    }

    @Test func legacyToolVersionStampsAreInvalidated() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-toolcache-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = ToolVersionCache.storeURL
        ToolVersionCache.storeURL = dir.appendingPathComponent("versions.json")
        defer { ToolVersionCache.storeURL = previous }

        let executable = dir.appendingPathComponent("tool")
        try "version one".write(to: executable, atomically: true, encoding: .utf8)
        let stamp = try #require(ToolVersionCache.stamp(for: executable))
        let legacy: [String: Any] = [
            executable.path: [
                "size": stamp.size,
                "modified": stamp.modified,
                "version": "1.0.0",
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: ToolVersionCache.storeURL)

        #expect(ToolVersionCache.cached(for: executable) == nil)
    }

    @Test func aToolThatIsNotThereHasNoRememberedVersion() {
        let missing = URL(fileURLWithPath: "/nope/not/a/tool")
        #expect(ToolVersionCache.stamp(for: missing) == nil)
        #expect(ToolVersionCache.cached(for: missing) == nil)
    }

    @Test func aBrokenToolSymlinkHasNoRememberedVersion() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-toolcache-broken-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("tool")
        try FileManager.default.createSymbolicLink(
            atPath: executable.path, withDestinationPath: "missing")

        #expect(ToolVersionCache.stamp(for: executable) == nil)
        #expect(ToolVersionCache.cached(for: executable) == nil)
    }

    @Test func aBrokenExecutableIsNotReportedInstalled() async throws {
        try await CLIProbe.inWorld { world in
            let executable = world.sandbox.appendingPathComponent("quinjet")
            try Data("#!/bin/sh\necho broken\nexit 7\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
            CLIEnvironment.executableNamed = { $0 == "quinjet" ? executable : nil }

            let json = await CLIProbe.capture(["tools", "ls", "--json"])
            let plain = await CLIProbe.capture(["tools", "ls"])
            let tools = json.array as? [[String: Any]]
            let quinjet = tools?.first { $0["id"] as? String == "quinjet" }

            #expect(json.code == 0)
            #expect(quinjet?["installed"] as? Bool == false)
            #expect(quinjet?["path"] as? String == executable.path)
            #expect(quinjet?["version"] is NSNull)
            #expect(plain.stdout.contains("quinjet"))
            #expect(plain.stdout.contains("broken"))
        }
    }

    @Test func toolHelpAndCompletionFollowProvisioningCatalog() async {
        let help = await CLIProbe.run(["tools", "install", "--help"])
        let completion = CompletionEngine.plan(
            CompletionRequest(words: ["ed", "tools", "install", ""], index: 3), machines: [],
            configKeys: [], extensionIDs: [])
        let ids = ToolProvisioning.all.map(\.id)

        #expect(help.code == 0)
        for id in ids { #expect(help.stdout.contains(id)) }
        #expect(completion.candidates == ids)
    }

    @Test func theCLIAndTheUIAgreeOnHowAPlaySourceIsSpelled() {
        #expect(
            MusicSourceRequest.folder("Albums/Live").payload as? [String: String]
                == ["sourceKind": "folder", "sourcePath": "Albums/Live"])
        #expect(
            MusicSourceRequest.favourites.payload as? [String: String]
                == ["sourceKind": "favourites"])
        for request: MusicSourceRequest in [
            .folder("a/b"), .directory("c"), .favourites, .all,
        ] {
            #expect(MusicSourceRequest.decode(request.payload) == request)
        }
        #expect(MusicSourceRequest.decode(["kind": "folder", "path": "a"]) == nil)
    }

    @Test func limitsRefreshThatGoesUnansweredIsAnErrorRatherThanStaleNumbers() async throws {
        await CLIProbe.inWorld { world in
            world.helperRunning(true)
            world.answers { _ in nil }
            let result = await CLIProbe.capture(["usage", "limits", "--refresh"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stdout.isEmpty)
        }
    }
}
