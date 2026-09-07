import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct DownloadWorkerTests {
    @Test func startupRecoversInterruptedWorkAndDrainsOldestQueuedDownloadFirst() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        let old = record("old", state: .queued, date: 1, directory: directory)
        let newer = record("new", state: .queued, date: 2, directory: directory)
        let interrupted = record("interrupted", state: .resolving, date: 0, directory: directory)
        try DownloadQueue.save([newer, interrupted, old], to: file)
        let gate = DownloadTestGate(directory: directory)
        let worker = worker(file, gate: gate)
        try await worker.start()
        try await eventually { await gate.started == ["old"] }
        #expect(await worker.snapshot().records.first { $0.id == interrupted.id }?.canRetry == true)
        await gate.release("old")
        try await eventually { await gate.started == ["old", "new"] }
        await gate.release("new")
        try await eventually { await worker.snapshot().running == 0 }
        #expect(await worker.snapshot().finished == 2)
        #expect(await gate.maximumActive == 1)
        #expect(DownloadQueue.load(from: file).filter { $0.resultPaths != nil }.count == 2)
    }

    @Test func concurrentMutationsHaveOneWriterAndRejectQueueOverflow() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        let worker = DownloadWorker(file: file, executable: { nil }, isEnabled: { true })
        try await worker.start()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0..<40 {
                group.addTask {
                    _ = try await worker.mutate(
                        .enqueue(
                            urls: [URL(string: "https://youtu.be/\(number)")!], prefix: "",
                            kind: .audio,
                            outputDirectory: directory))
                }
            }
            try await group.waitForAll()
        }
        #expect(await worker.snapshot().queued == 40)
        #expect(Set(DownloadQueue.load(from: file).map(\.id)).count == 40)
        await #expect(throws: AgentError.self) {
            _ = try await worker.mutate(
                .enqueue(
                    urls: Array(repeating: URL(string: "https://youtu.be/excess")!, count: 100),
                    prefix: "", kind: .audio, outputDirectory: directory))
        }
        #expect(await worker.snapshot().queued == 40)
    }

    @Test func malformedHistoryRemainsUntouchedAndRejectsMutations() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        let original = Data("not valid json".utf8)
        try original.write(to: file)
        let worker = DownloadWorker(file: file, executable: { nil }, isEnabled: { true })
        await #expect(throws: AgentError.self) { try await worker.start() }
        await #expect(throws: AgentError.self) {
            _ = try await worker.mutate(.clear(includeActive: true))
        }
        #expect(await worker.snapshot().problem != nil)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func failedPersistenceDoesNotLeaveAnUnacceptedDownloadInMemory() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-file")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let worker = DownloadWorker(file: file, executable: { nil }, isEnabled: { true })
        await #expect(throws: (any Error).self) {
            _ = try await worker.mutate(
                .enqueue(
                    urls: [URL(string: "https://youtu.be/fixture")!], prefix: "", kind: .audio,
                    outputDirectory: directory))
        }
        #expect(await worker.snapshot().records.isEmpty)
    }

    @Test func removalWaitsForCancellationBeforeTheNextDownloadStarts() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        let gate = DownloadTestGate(directory: directory)
        let worker = worker(file, gate: gate)
        try await worker.start()
        let added = try await worker.mutate(
            .enqueue(
                urls: [
                    URL(string: "https://youtu.be/first")!, URL(string: "https://youtu.be/second")!,
                ],
                prefix: "", kind: .audio, outputDirectory: directory)
        ).added
        try await eventually { await gate.started == ["first"] }
        _ = try await worker.mutate(.remove(id: added[0].id))
        try await eventually { await gate.started == ["first", "second"] }
        await gate.release("second")
        try await eventually { await worker.snapshot().running == 0 }
        #expect(await gate.maximumActive == 1)
        #expect(await worker.snapshot().records.count == 1)
        #expect(await worker.snapshot().finished == 1)
    }

    @Test func disablingStopsActiveWorkAndReenablingDrainsWaitingWork() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DownloadTestGate(directory: directory)
        let enabled = DownloadTestFlag()
        let worker = DownloadWorker(
            file: directory.appendingPathComponent("queue.json"),
            executable: { URL(fileURLWithPath: "/bin/sh") }, isEnabled: { enabled.value },
            runCommand: { request, line in try await gate.run(request, line: line) })
        try await worker.start()
        _ = try await worker.mutate(
            .enqueue(
                urls: [
                    URL(string: "https://youtu.be/first")!, URL(string: "https://youtu.be/second")!,
                ],
                prefix: "", kind: .audio, outputDirectory: directory))
        try await eventually { await gate.started == ["first"] }
        enabled.set(false)
        await worker.refresh()
        try await eventually { await worker.snapshot().running == 0 }
        #expect(await worker.snapshot().queued == 1)
        #expect(await worker.snapshot().failed == 1)
        enabled.set(true)
        await worker.refresh()
        try await eventually { await gate.started == ["first", "second"] }
        await gate.release("second")
        try await eventually { await worker.snapshot().finished == 1 }
    }

    @Test func daemonCancellationKillsRealDownloaderChildrenAndKeepsBoundedLiveLogs() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = DownloadWorker(
            file: directory.appendingPathComponent("queue.json"),
            executable: { URL(fileURLWithPath: "/bin/sh") }, isEnabled: { true },
            runCommand: { request, line in
                #expect(request.timeout == 7_200)
                #expect(request.maximumOutputBytes == 2 << 20)
                for _ in 0..<100 { line(String(repeating: "x", count: 4_000)) }
                return try await CLICommandRunner.runLocalSeparated(
                    CLICommandRequest(
                        executableURL: URL(fileURLWithPath: "/bin/sh"),
                        arguments: [
                            "-c", "(sleep 1; touch escaped) & echo '[download] 50.0% of'; wait",
                        ],
                        environment: ["PATH": "/usr/bin:/bin"], currentDirectoryURL: directory,
                        timeout: 5, maximumOutputBytes: 100_000, terminatesProcessGroup: true),
                    streamsWhileRunning: true, onStandardOutputLine: line,
                    onStandardErrorLine: { _ in })
            })
        try await worker.start()
        let added = try await worker.mutate(
            .enqueue(
                urls: [URL(string: "https://youtu.be/fixture")!], prefix: "", kind: .audio,
                outputDirectory: directory)
        ).added[0]
        try await eventually {
            await worker.snapshot().logs[added.id.uuidString]?.contains("50.0%") == true
        }
        #expect(await worker.snapshot().logs[added.id.uuidString]!.utf8.count <= 64_000)
        _ = try await worker.mutate(.cancel(id: added.id, includeQueued: true, reason: "Cancelled"))
        try await eventually { await worker.snapshot().running == 0 }
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("escaped").path))
        #expect(await worker.snapshot().records[0].status == .interrupted("Cancelled"))
    }

    @Test func resultIdentitySurvivesCommaFilenamesAndFolderChanges() throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        let completed = directory.appendingPathComponent("first, second.m4a")
        try Data().write(to: completed)
        var record = record(
            "fixture", state: .done("first, second.m4a"), date: 0, directory: directory)
        record.resultPaths = [completed.path]
        try DownloadQueue.save([record], to: file)
        let paths = try DownloadOperationExecution.resultURLs(
            id: record.id, root: directory.appendingPathComponent("changed"), file: file)
        #expect(paths == [completed])
        let result = CLICommandResult(
            terminationStatus: 0, output: "/etc/hosts\n\(completed.path)\n")
        #expect(
            DownloadWorker.resultPaths(result, record: record) == [
                completed.resolvingSymlinksInPath().path
            ])
    }

    @Test func estimateRunsAsABoundedDaemonTask() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = DownloadWorker(
            file: directory.appendingPathComponent("queue.json"),
            executable: { URL(fileURLWithPath: "/bin/sh") }, isEnabled: { true },
            runCommand: { request, _ in
                #expect(request.timeout == 30)
                #expect(request.maximumOutputBytes == 2 << 20)
                #expect(request.discardsStandardError)
                #expect(request.terminatesProcessGroup)
                return CLICommandResult(
                    terminationStatus: 0,
                    output: """
                        {"formats":[{"vcodec":"none","acodec":"aac","abr":128,"filesize":500}]}
                        """)
            })
        let tasks = try AgentTaskService(directory: nil)
        await worker.registerEstimate(on: tasks)
        let task = AgentTaskSubmission(
            operation: AgentDownloadOperation.estimate, title: "Estimate fixture",
            payload: try AgentPayload.encode(URL(string: "https://youtu.be/fixture")!))
        _ = try await tasks.submit(task)
        try await eventually {
            (try? await tasks.status(task.id).snapshot.state.isTerminal) == true
        }
        let result = try await tasks.status(task.id)
        #expect(result.snapshot.state == .succeeded)
        #expect(
            try AgentPayload.decode(DownloadEstimate.self, from: result.result!).audioBytes == 500)
    }

    @Test @MainActor func displaySnapshotsNeverAdoptAnOlderQueueRevision() throws {
        let downloader = YoutubeDownloader(start: false)
        let generation = UUID()
        let item = record(
            "fixture", state: .queued, date: 0, directory: FileManager.default.temporaryDirectory)
        downloader.apply(
            DownloadWorkerSnapshot(
                records: [item], logs: [:], enabled: true,
                running: false, generation: generation, revision: 2))
        downloader.apply(
            DownloadWorkerSnapshot(
                records: [], logs: [:], enabled: true,
                running: false, generation: generation, revision: 1))
        #expect(downloader.items.map(\.id) == [item.id])
        downloader.apply(
            DownloadWorkerSnapshot(
                records: [], logs: [:], enabled: true,
                running: false, generation: UUID(), revision: 0))
        #expect(downloader.items.isEmpty)
    }

    private func worker(_ file: URL, gate: DownloadTestGate) -> DownloadWorker {
        DownloadWorker(
            file: file, executable: { URL(fileURLWithPath: "/bin/sh") },
            isEnabled: { true },
            runCommand: { request, line in try await gate.run(request, line: line) })
    }

    private func record(_ name: String, state: DownloadStatus, date: TimeInterval, directory: URL)
        -> DownloadRecord
    {
        DownloadRecord(
            url: URL(string: "https://youtu.be/\(name)")!, status: state,
            outputFilename: DownloadQueue.outputTemplate(prefix: "", directory: directory),
            createdAt: Date(timeIntervalSince1970: date), kind: .audio)
    }

    private func sandbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-worker-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}

private actor DownloadTestGate {
    let directory: URL
    var started: [String] = []
    var maximumActive = 0
    private var active = 0
    private var released: Set<String> = []

    init(directory: URL) { self.directory = directory }
    func release(_ name: String) { released.insert(name) }

    func run(_ request: CLICommandRequest, line: @escaping @Sendable (String) -> Void) async throws
        -> CLICommandResult
    {
        let name = URL(string: request.arguments.last!)!.lastPathComponent
        started.append(name)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        line("[download] 10.0% of")
        while !released.contains(name) { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        let result = directory.appendingPathComponent("\(name).m4a")
        try Data().write(to: result)
        return CLICommandResult(terminationStatus: 0, output: result.path + "\n")
    }
}

private final class DownloadTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    var value: Bool { lock.withLock { enabled } }
    func set(_ value: Bool) { lock.withLock { enabled = value } }
}
