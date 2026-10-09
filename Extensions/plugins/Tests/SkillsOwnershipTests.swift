import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import PluginsExtension

@Suite struct SkillsOwnershipTests {
    private let skill = EdithSkillLibrary.skills[0]
    private let markdown = "---\nname: edith-remote-work\n---\n# Synthetic skill\n"

    @Test func canceledInstallerCannotVerifyFilesOrRecordSuccessAfterCommandExit() async throws {
        let gate = Gate()
        let installer = SkillInstaller(recordInstalled: { _, _ in
            Issue.record("A canceled installation must not publish success.")
        }) { _, _ in
            await gate.pause()
            return CLICommandResult(terminationStatus: 0, output: "synthetic result")
        }
        let task = Task {
            try await installer.install(
                skill: skill, agentIDs: ["cursor"], home: URL(fileURLWithPath: "/synthetic/home"),
                environment: [:])
        }
        try await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @MainActor @Test func disableCancelsDocumentRequestsAndRejectsTheirLateCacheWrites()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        let body = markdown
        let store = SkillDocumentStore(cacheDirectory: root) { _ in
            await gate.pause()
            return Data(body.utf8)
        }
        let request = Task { try await store.load(skill) }
        try await gate.waitUntilStarted()
        let stopping = Task { await store.shutdown() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !store.isStopped, ContinuousClock.now < deadline { await Task.yield() }
        #expect(store.isStopped)
        await gate.release()
        await stopping.value
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(store.cachedDocument(for: skill) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor @Test func canceledPreviewCannotWriteAResponseThatArrivesAfterCancellation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        let body = markdown
        let store = SkillDocumentStore(cacheDirectory: root) { _ in
            await gate.pause()
            return Data(body.utf8)
        }
        let request = Task { try await store.load(skill) }
        try await gate.waitUntilStarted()
        request.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        await store.shutdown()
    }

    @Test(arguments: ["asset", "total", "fileCount", "fifo"])
    func installerRejectsUnboundedPackagesAndNonRegularFiles(mode: String) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".agents/skills/edith-remote-work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        switch mode {
        case "asset", "total":
            for index in 0..<(mode == "total" ? 2 : 1) {
                let file = folder.appendingPathComponent("asset-\(index)")
                FileManager.default.createFile(atPath: file.path, contents: Data())
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: UInt64((mode == "total" ? 16 : 17) * 1_024 * 1_024))
                try handle.close()
            }
        case "fileCount":
            for index in 0..<4096 {
                FileManager.default.createFile(
                    atPath: folder.appendingPathComponent("file-\(index)").path, contents: Data())
            }
        case "fifo": #expect(mkfifo(folder.appendingPathComponent("fifo").path, 0o600) == 0)
        default: Issue.record("Unknown fixture")
        }
        let installer = SkillInstaller(recordInstalled: { _, _ in
            Issue.record("Unbounded packages must not publish success.")
        }) { _, _ in CLICommandResult(terminationStatus: 0, output: "synthetic result") }
        await #expect(throws: SkillsError.self) {
            try await installer.install(
                skill: skill, agentIDs: ["cursor"], home: home, environment: [:])
        }
    }

    private actor Gate {
        private var started = false
        private var continuation: CheckedContinuation<Void, Never>?

        func pause() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started = true
            }
        }

        func release() {
            let continuation = continuation
            self.continuation = nil
            continuation?.resume()
        }

        func waitUntilStarted() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !started, ContinuousClock.now < deadline { await Task.yield() }
            guard started else { throw SkillsError.message("The synthetic request did not start.") }
        }
    }
}
