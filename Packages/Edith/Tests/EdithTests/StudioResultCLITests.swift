import EdithStudio
import Foundation
import Testing

@testable import Edith
@testable import EdithCLI
@testable import EdithKit

@Suite struct StudioResultCLITests {
    @Test func commandsParse() throws {
        #expect(try EdRoot.parseAsRoot(["studio", "cancel"]) is StudioCancelCommand)
        #expect(try EdRoot.parseAsRoot(["studio", "reveal", "report.pdf"]) is StudioRevealCommand)
        #expect(try EdRoot.parseAsRoot(["studio", "open", "report.pdf"]) is StudioOpenCommand)
    }

    @Test func resultJSONNamesTheActionAndPaths() {
        let value = StudioResultCLI.payload(action: "reveal", paths: ["/tmp/report.pdf"])
        guard case let .object(fields) = value else {
            Issue.record("expected an object")
            return
        }
        #expect(fields["action"] == .string("reveal"))
        #expect(fields["paths"] == .array([.string("/tmp/report.pdf")]))
    }

    @Test func cancelReportsTheWindowReply() async {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { name in
                guard name == IPC.Name.studioJobResult else { return nil }
                let requestID =
                    world.postedPayloads(for: IPC.Name.requestStudioCancel).last?["requestID"]
                    as? String ?? ""
                return [
                    "ok": true, "requestID": requestID, "cancelled": "1", "tools": "pdf.merge",
                ]
            }
            let result = await CLIProbe.capture(["studio", "cancel", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["action"] as? String == "cancel")
            #expect(result.object?["cancelled"] as? Int == 1)
            #expect(result.object?["tools"] as? [String] == ["pdf.merge"])
            #expect(world.postedNames() == [IPC.Name.requestStudioCancel.rawValue])
        }
    }

    @Test func cancelWithNothingRunningSaysSo() async {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { name in
                guard name == IPC.Name.studioJobResult else { return nil }
                let requestID =
                    world.postedPayloads(for: IPC.Name.requestStudioCancel).last?["requestID"]
                    as? String ?? ""
                return ["ok": true, "requestID": requestID, "cancelled": "0", "tools": ""]
            }
            let result = await CLIProbe.capture(["studio", "cancel"])
            #expect(result.code == 0)
            #expect(result.stdout.contains("no Studio run is in progress"))
        }
    }

    @Test func cancelNeedsTheMainWindow() async {
        let result = await CLIProbe.run(["studio", "cancel"])
        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stderr.contains("main window"))
    }

    @Test func revealSelectsExistingFilesAndSkipsMissingOnes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-studio-reveal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("report.pdf")
        try Data("synthetic".utf8).write(to: file)
        await CLIProbe.inWorld { _ in
            let revealed = RevealedPaths()
            let previous = StudioFinderReveal.revealFiles
            StudioFinderReveal.revealFiles = { urls in revealed.add(urls.map(\.path)) }
            defer { StudioFinderReveal.revealFiles = previous }
            let result = await CLIProbe.capture(["studio", "reveal", file.path, "--json"])
            #expect(result.code == 0)
            #expect(result.object?["action"] as? String == "reveal")
            #expect(result.object?["paths"] as? [String] == [file.path])
            #expect(revealed.values == [file.path])
            let missing = await CLIProbe.capture(["studio", "reveal", folder.path + "/gone.pdf"])
            #expect(missing.code == ExitCodes.notFound)
        }
    }

    @Test func openHandsEachFileToTheSharedOpener() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-studio-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("report.pdf")
        try Data("synthetic".utf8).write(to: file)
        let opened = RevealedPaths()
        await CLIProbe.inWorld { _ in
            let previous = StudioFinderReveal.openFile
            StudioFinderReveal.openFile = { opened.add([$0.path]) }
            defer { StudioFinderReveal.openFile = previous }
            let result = await CLIProbe.capture(["studio", "open", file.path, "--json"])
            #expect(result.code == 0)
            #expect(result.object?["action"] as? String == "open")
            #expect(result.object?["paths"] as? [String] == [file.path])
            #expect(opened.values == [file.path])
        }
    }
}

@Suite struct StudioRunRegistryTests {
    @Test @MainActor func cancelStopsOnlyTheRunningJob() {
        let tool = StudioCatalog.tool("pdf.merge") ?? StudioCatalog.tools[0]
        let running = StudioJob(tool: tool, inputs: [])
        let idle = StudioJob(tool: tool, inputs: [])
        running.phase = .running
        StudioRunRegistry.track(running)
        StudioRunRegistry.track(idle)
        defer {
            StudioRunRegistry.release(running)
            StudioRunRegistry.release(idle)
        }
        #expect(StudioRunRegistry.cancelRunning() == [tool.id])
        #expect(running.phase == .failed(StudioError.cancelled.localizedDescription))
        #expect(idle.phase == .editing)
        #expect(StudioRunRegistry.cancelRunning().isEmpty)
    }
}

private final class RevealedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func add(_ paths: [String]) {
        lock.lock()
        self.paths.append(contentsOf: paths)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}
