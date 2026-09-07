import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentDownloadTransportTests {
    @Test func commandLineReadsCurrentProgressThroughTheDaemonSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let worker = DownloadWorker(
            file: file, executable: { URL(fileURLWithPath: "/bin/sh") },
            isEnabled: { true },
            runCommand: { _, line in
                line("[download] 10.0% of")
                try await Task.sleep(for: .seconds(30))
                return CLICommandResult(terminationStatus: 0, output: "")
            })
        await AgentOperations.register(on: runtime, downloads: worker)
        try await worker.start()
        _ = try await worker.mutate(
            .enqueue(
                urls: [URL(string: "https://example.com/fixture")!],
                prefix: "", kind: .audio, outputDirectory: directory))
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = AgentDownloadClient(client: listener.client())
        var records: [DownloadRecord] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            records = await DownloadOperationExecution.liveRecords(client: client)
            if records.first?.state == "downloading" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(DownloadQueueSnapshot(records: records).downloading == 1)
        #expect(DownloadQueue.load(from: file).first?.status == .resolving)
        let offline = await DownloadOperationExecution.liveRecords(file: file)
        #expect(offline.first?.status == .resolving)
        await worker.stop()
    }

    @Test func downloadFinishesAfterClientDisconnectAndPublishesItsCompletedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-xpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("completed.m4a")
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let worker = DownloadWorker(
            file: directory.appendingPathComponent("queue.json"),
            executable: { URL(fileURLWithPath: "/bin/sh") }, isEnabled: { true },
            runCommand: { _, line in
                try await CLICommandRunner.runLocalSeparated(
                    CLICommandRequest(
                        executableURL: URL(fileURLWithPath: "/bin/sh"),
                        arguments: [
                            "-c",
                            "echo '[download] 50.0% of'; sleep 0.1; printf fixture > completed.m4a; printf '%s/completed.m4a\\n' \"$PWD\"",
                        ],
                        environment: [:], currentDirectoryURL: directory,
                        timeout: 2, maximumOutputBytes: 1_024, terminatesProcessGroup: true),
                    streamsWhileRunning: true, onStandardOutputLine: line,
                    onStandardErrorLine: { _ in })
            },
            publish: { snapshot in
                if let payload = try? AgentPayload.encode(snapshot) {
                    await runtime.publish(topic: .downloads, payload: payload)
                }
            })
        await AgentOperations.register(on: runtime, downloads: worker)
        try await worker.start()
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let original = AgentDownloadClient(client: listener.client())
        let receipt = try await original.mutateAsync(
            .enqueue(
                urls: [URL(string: "https://youtu.be/fixture")!], prefix: "", kind: .audio,
                outputDirectory: directory))
        #expect(receipt.added.count == 1)
        original.client.reset()
        let replacement = AgentDownloadClient(client: listener.client())
        let finished = DownloadTransportFlag()
        let stream = try await replacement.client.subscribeAsync(.downloads) { data in
            if let snapshot = try? AgentPayload.decode(DownloadWorkerSnapshot.self, from: data),
                snapshot.finished == 1
            {
                finished.set()
            }
        }
        defer { stream.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !finished.value, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(finished.value)
        let snapshot = try await replacement.snapshot()
        #expect(snapshot.records[0].id == receipt.added[0].id)
        #expect(snapshot.records[0].resultPaths == [output.resolvingSymlinksInPath().path])
        #expect(try String(contentsOf: output, encoding: .utf8) == "fixture")
        #expect(snapshot.running == 0)
        let fromTopic = try await replacement.client.snapshotAsync(
            DownloadWorkerSnapshot.self, topic: .downloads)
        #expect(fromTopic.finished == 1)
    }
}

private final class DownloadTransportFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var value: Bool { lock.withLock { finished } }
    func set() { lock.withLock { finished = true } }
}
