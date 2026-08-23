import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIAppInspectionTests {
    @Test func infoHasStablePlainAndJSONContracts() async throws {
        let plain = await CLIProbe.run(["app", "info"])
        let json = await CLIProbe.run(["app", "info", "--json"])

        #expect(plain.code == 0)
        #expect(plain.stdout.contains("FIELD"))
        #expect(plain.stdout.contains("version"))
        #expect(plain.stderr.isEmpty)
        #expect(json.code == 0)
        #expect(
            Set(json.object?.keys ?? [:].keys) == [
                "name", "version", "build", "bundleID", "bundlePath", "repositoryURL",
                "creatorURL",
            ])
        #expect(json.object?["repositoryURL"] as? String == "https://github.com/pulkitxm/edith")
        #expect(json.stderr.isEmpty)
    }

    @Test func diagnosticsReadsTheHelperSnapshotInPlainAndJSON() async {
        let snapshot = AppDiagnosticsSnapshot(
            info: AppInfoSnapshot(
                name: "Edith", version: "1.2", build: "34", bundleID: "com.pulkit.edith",
                bundlePath: "/Applications/Edith.app",
                repositoryURL: AppInspectionCenter.repositoryURL,
                creatorURL: AppInspectionCenter.creatorURL),
            processID: 42, uptimeSeconds: 3_661, idleWakeups: 17)
        let plain = await CLIProbe.runInWorld(["app", "diagnostics"]) { world in
            world.helperRunning(true)
            world.answers { name in
                name == IPC.Name.appDiagnostics ? AppDiagnosticsPayload.encode(snapshot) : nil
            }
        }
        let json = await CLIProbe.runInWorld(["app", "diagnostics", "--json"]) { world in
            world.helperRunning(true)
            world.answers { name in
                name == IPC.Name.appDiagnostics ? AppDiagnosticsPayload.encode(snapshot) : nil
            }
        }

        #expect(plain.code == 0)
        #expect(plain.stdout.contains("1h 1m"))
        #expect(plain.stdout.contains("17"))
        #expect(json.code == 0)
        #expect(json.object?["pid"] as? Int == 42)
        #expect(json.object?["uptimeSeconds"] as? Int == 3_661)
        #expect(json.object?["idleWakeups"] as? Int == 17)
        #expect((json.object?["info"] as? [String: Any])?["version"] as? String == "1.2")
    }

    @Test func diagnosticsNeedsTheHelperAndLeavesJSONStdoutEmpty() async {
        let result = await CLIProbe.run(["app", "diagnostics", "--json"])

        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("menu bar app"))
    }

    @Test func pathsAndLinksExposeTypedStableRows() async {
        let paths = await CLIProbe.run(["app", "paths", "--json"])
        let links = await CLIProbe.run(["app", "links", "--json"])

        #expect(paths.code == 0)
        let pathRows = paths.array as? [[String: Any]]
        #expect(pathRows?.compactMap { $0["id"] as? String } == AppPathID.allCases.map(\.rawValue))
        #expect(pathRows?.allSatisfy { Set($0.keys) == ["id", "label", "path", "exists"] } == true)
        #expect(links.code == 0)
        let linkRows = links.array as? [[String: Any]]
        let linkIDs = linkRows?.compactMap { $0["id"] as? String }
        #expect(Array(linkIDs?.prefix(2) ?? []) == ["repository", "creator"])
        #expect(linkIDs?.contains("extension-doc:usage:guide") == true)
        #expect(linkRows?.allSatisfy { Set($0.keys) == ["id", "label", "url"] } == true)
    }

    @Test func openCommandsOnlyOpenTheNamedExactTargets() async {
        let box = RunBox()
        var opened: [URL] = []
        await CLIProbe.inWorld { world in
            box.value = await CLIProbe.capture(["app", "open-path", "app-data", "--json"])
            opened = world.opened()
        }

        #expect(box.value.code == 0)
        #expect(box.value.object?["id"] as? String == "app-data")
        #expect(box.value.object?["opened"] as? Bool == true)
        #expect(opened == [AppData.supportDir])

        await CLIProbe.inWorld { world in
            box.value = await CLIProbe.capture(["app", "open-link", "repository", "--json"])
            opened = world.opened()
        }

        #expect(box.value.code == 0)
        #expect(box.value.object?["id"] as? String == "repository")
        #expect(opened == [AppInspectionCenter.repositoryURL])
    }

    @Test func developerPathsOpenOrRevealOnlyTheirResolvedTarget() async {
        let log = Repo.dataDir.appendingPathComponent("refresh.log")
        let data = RunBox()
        var opened: [URL] = []
        await CLIProbe.inWorld { world in
            data.value = await CLIProbe.capture(["app", "open-path", "data", "--json"])
            opened = world.opened()
        }
        #expect(data.value.code == 0)
        #expect(opened == [Repo.dataDir])

        let missing = RunBox()
        await CLIProbe.inWorld { world in
            missing.value = await CLIProbe.capture(
                ["app", "open-path", "refresh-log", "--json"])
            opened = world.opened()
        }
        #expect(missing.value.object?["mode"] as? String == "open")
        #expect(opened == [Repo.dataDir])

        let present = RunBox()
        var revealed: [[URL]] = []
        await CLIProbe.inWorld { world in
            world.appPaths(existing: [log])
            present.value = await CLIProbe.capture(
                ["app", "open-path", "refresh-log", "--json"])
            opened = world.opened()
            revealed = world.revealed()
        }
        #expect(present.value.object?["mode"] as? String == "reveal")
        #expect(opened.isEmpty)
        #expect(revealed == [[log]])
    }

    @Test func extensionDocumentationOpensThroughTheSharedLinkCatalog() async {
        let result = RunBox()
        var opened: [URL] = []
        await CLIProbe.inWorld { world in
            result.value = await CLIProbe.capture(
                ["app", "open-link", "extension-doc:usage:guide", "--json"])
            opened = world.opened()
        }

        #expect(result.value.code == 0)
        #expect(result.value.object?["id"] as? String == "extension-doc:usage:guide")
        #expect(
            opened.map(\.absoluteString) == [
                "https://github.com/pulkitxm/edith/blob/main/docs/cli/usage/README.md"
            ])
    }

    @Test func anUnknownLinkIsANotFoundFailure() async {
        let result = await CLIProbe.run(["app", "open-link", "missing", "--json"])

        #expect(result.code == ExitCodes.notFound)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("ed app links"))
    }
}

@Suite struct CLIAppInspectionProcessTests {
    @Test func safeReadsWorkOutsideARepository() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-app-inspection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        for arguments in [
            ["app", "info", "--json"], ["app", "paths", "--json"],
            ["app", "links", "--json"],
        ] {
            let result = try CLIProcessProbe.run(arguments, currentDirectory: outside)
            #expect(result.code == 0, "\(arguments) failed: \(result.stderr)")
            #expect((try? result.decoded()) != nil)
            #expect(result.stderr.isEmpty)
        }
    }
}
