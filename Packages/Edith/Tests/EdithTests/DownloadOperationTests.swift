import Foundation
import Testing

@testable import EdithKit

@Suite struct DownloadOperationTests {
    private func sandbox() throws -> (directory: URL, queue: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-download-operation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("downloads.json"))
    }

    private func record(
        _ state: DownloadStatus, at date: Date, id: UUID = UUID(),
        url: String = "https://youtu.be/a"
    ) -> DownloadRecord {
        DownloadRecord(
            id: id, url: URL(string: url)!, status: state, outputFilename: nil,
            createdAt: date, kind: .audio)
    }

    @Test func listIsStableAndStatusCountsEveryLifecycleState() throws {
        let sandbox = try sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.directory) }
        let now = Date(timeIntervalSince1970: 1_000)
        let records = [
            record(.error("failed"), at: now.addingTimeInterval(-4)),
            record(.done("song.m4a"), at: now.addingTimeInterval(-3)),
            record(.downloading(progress: "50%", videoIndex: 1, videoCount: 1), at: now),
            record(.interrupted("cancelled"), at: now.addingTimeInterval(-5)),
            record(.queued, at: now.addingTimeInterval(-1)),
            record(.resolving, at: now.addingTimeInterval(-2)),
        ]
        try DownloadQueue.save(records, to: sandbox.queue)

        let listed = DownloadOperationExecution.list(limit: 0, file: sandbox.queue)
        #expect(listed.map(\.createdAt) == listed.map(\.createdAt).sorted(by: >))
        #expect(
            DownloadOperationExecution.list(activeOnly: true, limit: 2, file: sandbox.queue).count
                == 2)
        let status = DownloadOperationExecution.status(file: sandbox.queue)
        #expect(status.total == 6)
        #expect(status.active == 3)
        #expect(status.finished == 3)
        #expect(status.queued == 1)
        #expect(status.resolving == 1)
        #expect(status.downloading == 1)
        #expect(status.done == 1)
        #expect(status.failed == 1)
        #expect(status.interrupted == 1)
    }

    @Test func enqueueRetryCancelRemoveAndClearShareOneQueue() throws {
        let sandbox = try sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.directory) }
        let output = sandbox.directory.appendingPathComponent("music")
        let urls = [URL(string: "https://youtu.be/one")!, URL(string: "https://youtu.be/two")!]
        let added = try DownloadOperationExecution.enqueue(
            urls: urls, prefix: "focus-", now: Date(timeIntervalSince1970: 2_000),
            file: sandbox.queue, outputDirectory: output)
        #expect(added.count == 2)
        #expect(added.allSatisfy { $0.outputFilename?.contains("focus-%(title)s") == true })

        let cancelled = try DownloadOperationExecution.cancel(file: sandbox.queue)
        #expect(cancelled.changed == 2)
        #expect(cancelled.records.allSatisfy { $0.canRetry })
        let retried = try DownloadOperationExecution.retry(index: 1, file: sandbox.queue)
        #expect(retried.changed == 1)
        let removed = try DownloadOperationExecution.remove(index: 1, file: sandbox.queue)
        #expect(removed.changed == 1)
        #expect(removed.remaining == 1)
        let clearedFinished = try DownloadOperationExecution.clear(file: sandbox.queue)
        #expect(clearedFinished.changed == 1)
        #expect(clearedFinished.remaining == 0)
    }

    @Test func cancellationCanTargetOneStableRecordIdentity() throws {
        let sandbox = try sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.directory) }
        let first = record(.queued, at: Date(timeIntervalSince1970: 2), id: UUID())
        let second = record(.resolving, at: Date(timeIntervalSince1970: 1), id: UUID())
        try DownloadQueue.save([first, second], to: sandbox.queue)

        let result = try DownloadOperationExecution.cancel(id: second.id, file: sandbox.queue)
        #expect(result.changed == 1)
        #expect(result.records.first { $0.id == first.id }?.status == .queued)
        #expect(result.records.first { $0.id == second.id }?.status == .interrupted("Cancelled"))
        #expect(throws: DownloadOperationError.self) {
            try DownloadOperationExecution.cancel(index: 2, file: sandbox.queue)
        }
    }

    @Test func startupRecoveryInterruptsInFlightWorkButKeepsQueuedWork() throws {
        let sandbox = try sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.directory) }
        let queued = record(.queued, at: Date(timeIntervalSince1970: 3))
        let resolving = record(.resolving, at: Date(timeIntervalSince1970: 2))
        let downloading = record(
            .downloading(progress: "8%", videoIndex: 0, videoCount: 0),
            at: Date(timeIntervalSince1970: 1))
        try DownloadQueue.save([queued, resolving, downloading], to: sandbox.queue)

        let result = try DownloadOperationExecution.cancel(
            includeQueued: false, reason: "Interrupted", file: sandbox.queue)
        #expect(result.changed == 2)
        #expect(result.records.first { $0.id == queued.id }?.status == .queued)
        #expect(result.records.first { $0.id == resolving.id }?.canRetry == true)
        #expect(result.records.first { $0.id == downloading.id }?.canRetry == true)
    }

    @Test func processCancellationOnlyTerminatesTheTargetedRecord() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        let current = UUID()

        #expect(
            !DownloadProcessControl.cancel(
                currentID: current, targetID: UUID(), terminate: { process.terminate() }))
        #expect(process.isRunning)
        #expect(
            DownloadProcessControl.cancel(
                currentID: current, targetID: current, terminate: { process.terminate() }))
        process.waitUntilExit()
        #expect(!process.isRunning)
    }

    @Test func toolStatusAndUpdateUseTheSameInjectedCommandRunner() async throws {
        let executable = URL(fileURLWithPath: "/tmp/yt-dlp")
        let run: ToolVersionProbe.RunCommand = { request, _ in
            let output = request.arguments == ["-U"] ? "updated\n" : "2026.08.23\n"
            return CLICommandResult(terminationStatus: 0, output: output)
        }

        let status = await DownloadToolOperationExecution.status(
            executable: executable, runCommand: run)
        let update = try await DownloadToolOperationExecution.update(
            executable: executable, runCommand: run)

        #expect(status.version == "2026.08.23")
        #expect(update.output == "updated")
        #expect(update.before == "2026.08.23")
        #expect(update.after == "2026.08.23")
    }

    @MainActor
    @Test func resultActionsResolveOnlyExistingCompletedFiles() throws {
        let sandbox = try sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.directory) }
        let id = UUID()
        try DownloadQueue.save(
            [record(.done("first.m4a, nested/second.m4a"), at: Date(), id: id)],
            to: sandbox.queue)
        let existing = Set(["first.m4a", "second.m4a"])
        var revealed: [URL] = []
        let urls = try DownloadOperationExecution.reveal(
            id: id, root: sandbox.directory, file: sandbox.queue,
            exists: { existing.contains(URL(fileURLWithPath: $0).lastPathComponent) },
            using: { revealed = $0 })
        #expect(urls == revealed)
        #expect(urls.map(\.lastPathComponent) == ["first.m4a", "second.m4a"])
        var opened: [URL] = []
        _ = try DownloadOperationExecution.open(
            id: id, root: sandbox.directory, file: sandbox.queue, exists: { _ in true },
            using: {
                opened.append($0)
                return true
            })
        #expect(opened == urls)
        #expect(throws: DownloadOperationError.self) {
            try DownloadOperationExecution.resultURLs(
                id: id, root: sandbox.directory, file: sandbox.queue, exists: { _ in false })
        }
    }
}
