import DownloadsHistory
import EdithExtensionSupport
import Foundation
import MusicHistory
import Testing

@Suite struct DownloadHistoryTests {
    @Test func fixtureEnvironmentStaysIsolated() throws {
        let values = ProcessInfo.processInfo.environment
        let base = try #require(values["HISTORY_FIXTURE_ROOT"])
        let parent = URL(fileURLWithPath: base).deletingLastPathComponent()
            .deletingLastPathComponent().path
        for key in ["HOME", "CFFIXED_USER_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "TMPDIR"] {
            #expect(try #require(values[key]).hasPrefix(parent + "/"))
        }
        #expect(values["HOME"] == values["CFFIXED_USER_HOME"])
        #expect(values["PYTHONDONTWRITEBYTECODE"] == "1")
    }

    @Test func originalProductionHistoryAndSourceAssociationSurviveReplacement() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let edith = root.appendingPathComponent("Edith")
        let musicEnvironment = environment(owner: "music", root: edith)
        let downloadsEnvironment = environment(owner: "downloads", root: edith)
        let original = edith.appendingPathComponent("data/downloads.json")
        let resolved = MusicStorage.resolvedDownloadQueueFile(environment: musicEnvironment)
        #expect(resolved == original)
        let downloadsRoot = ExtensionData.resolve(environment: downloadsEnvironment, fallback: root)
        #expect(downloadsRoot.appendingPathComponent("downloads.json") == original)
        #expect(ExtensionData.productionLeaves["music"]!.contains("data/downloads.json"))
        #expect(ExtensionData.productionLeaves["downloads"]!.contains("data/downloads.json"))
        let output = root.appendingPathComponent("retained.m4a")
        try Data("synthetic file".utf8).write(to: output)
        let record = MusicHistory.DownloadRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
            url: URL(string: "https://example.invalid/original-source")!,
            status: .done("retained.m4a"),
            outputFilename: root.appendingPathComponent("%(title)s.%(ext)s").path,
            createdAt: Date(timeIntervalSince1970: 42), kind: .audio, resultPaths: [output.path],
            browser: .firefox)
        try MusicHistory.DownloadQueue.save([record], to: original)
        let before = try Data(contentsOf: original)
        for _ in 0..<2 {
            let worker = MusicHistory.DownloadWorker(file: resolved, executable: { nil })
            try await worker.start()
            #expect(await worker.snapshot().records == [record])
            await worker.stop()
        }
        let retained = try #require(DownloadsHistory.DownloadQueue.read(from: original).first)
        #expect(retained.id == record.id)
        #expect(retained.url == record.url)
        #expect(retained.resultPaths == [output.path])
        #expect(retained.status == .done("retained.m4a"))
        let projection = MusicHistory.YoutubeDownloader(
            records: try MusicHistory.DownloadQueue.read(from: original))
        #expect(projection.sourceURL(forFileNamed: "retained.m4a") == record.url)
        #expect(try Data(contentsOf: original) == before)
        #expect(try Data(contentsOf: output) == Data("synthetic file".utf8))
        #expect(
            !FileManager.default.fileExists(
                atPath: edith.appendingPathComponent("downloads.json").path))
        let development = environment(
            owner: "music", root: edith, identifier: "com.pulkit.edith.dev.fixture")
        #expect(
            MusicStorage.resolvedDownloadQueueFile(environment: development)
                == edith.appendingPathComponent("Data/music/downloads.json"))
    }

    @Test func twoOwnersKeepConcurrentAddsAndRejectCorruptHistory() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("downloads.json")
        let music = MusicHistory.DownloadWorker(file: file, executable: { nil })
        let downloads = DownloadsHistory.DownloadWorker(file: file, executable: { nil })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let url = URL(string: "https://example.invalid/item\(index)")!
                    if index.isMultiple(of: 2) {
                        _ = try await music.mutate(
                            .enqueue(urls: [url], prefix: "", kind: .audio, outputDirectory: root))
                    } else {
                        _ = try await downloads.mutate(
                            .enqueue(urls: [url], prefix: "", kind: .audio, outputDirectory: root))
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try MusicHistory.DownloadQueue.read(from: file).count == 40)
        #expect(await music.snapshot().records.count == 40)
        #expect(await downloads.snapshot().records.count == 40)
        let badFile = root.appendingPathComponent("corrupt.json")
        let original = Data("invalid synthetic queue".utf8)
        try original.write(to: badFile)
        #expect(throws: (any Error).self) {
            try DownloadsHistory.DownloadQueue.enqueue(
                urls: [URL(string: "https://example.invalid/new")!], file: badFile,
                outputDirectory: root)
        }
        #expect(try Data(contentsOf: badFile) == original)
    }

    @Test func oneSchedulerCrossOwnerCancellationLateFinishAndHandoff() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("downloads.json")
        let gate = FakeRunner(root: root)
        let music = MusicHistory.DownloadWorker(
            file: file, executable: { URL(fileURLWithPath: "/synthetic/downloader") },
            runCommand: { request, line in try await gate.run(request.arguments.last!, line: line) }
        )
        let downloads = DownloadsHistory.DownloadWorker(
            file: file, executable: { URL(fileURLWithPath: "/synthetic/downloader") },
            runCommand: { request, line in try await gate.run(request.arguments.last!, line: line) }
        )
        try await music.start()
        let added = try await downloads.mutate(
            .enqueue(
                urls: (0..<5).map { URL(string: "https://example.invalid/job\($0)")! },
                prefix: "", kind: .audio, outputDirectory: root)
        ).added
        try await eventually { await gate.started.count == 3 }
        try await downloads.start()
        try await eventually {
            await downloads.snapshot().records.filter {
                if case .downloading = $0.status { return true }; return false
            }.count == 3
        }
        #expect(await gate.started.count == 3)
        let running = await gate.started
        let removed = try #require(added.first { running.contains($0.url.absoluteString) })
        let retried = try #require(
            added.first { $0.id != removed.id && running.contains($0.url.absoluteString) })
        _ = try await downloads.mutate(.remove(id: removed.id))
        _ = try await downloads.mutate(
            .cancel(id: retried.id, includeQueued: true, reason: "synthetic cancel"))
        _ = try await downloads.mutate(.retry(id: retried.id, all: false))
        await music.refresh()
        await gate.release(removed.url.absoluteString)
        await gate.release(retried.url.absoluteString)
        try await eventually { await gate.started.count >= 5 }
        #expect(!DownloadsHistory.DownloadQueue.load(from: file).contains { $0.id == removed.id })
        await music.stop()
        await downloads.refresh()
        await gate.releaseAll()
        try await eventually {
            let snapshot = await downloads.snapshot()
            return snapshot.queued == 0 && snapshot.running == 0
        }
        let persisted = try DownloadsHistory.DownloadQueue.read(from: file)
        #expect(persisted.count == 4)
        #expect(Set(persisted.map(\.id)).count == 4)
        #expect(await gate.maximumActive <= 3)
        #expect(await gate.duplicateWhileActive == false)
        await downloads.stop()
    }

    @Test func separateOwnerProcessesSerializeAdmissionsAndWrites() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("downloads.json")
        _ = try MusicHistory.DownloadQueue.enqueue(
            urls: (0..<12).map { URL(string: "https://example.invalid/process-job\($0)")! },
            file: file, outputDirectory: root)
        let package = try #require(ProcessInfo.processInfo.environment["HISTORY_CHILD_PACKAGE"])
        let candidates = [".build/out/Products/Debug/HistoryChild", ".build/debug/HistoryChild"]
        let executable = try #require(
            candidates.map { URL(fileURLWithPath: package).appendingPathComponent($0) }.first {
                FileManager.default.isExecutableFile(atPath: $0.path)
            })
        let processes = ["music", "downloads"].map { owner in
            let process = Process()
            process.executableURL = executable
            process.arguments = [owner, file.path, root.path]
            process.environment = ProcessInfo.processInfo.environment
            return process
        }
        for process in processes { try process.run() }
        for process in processes {
            process.waitUntilExit(); #expect(process.terminationStatus == 0)
        }
        let records = try DownloadsHistory.DownloadQueue.read(from: file)
        let admissions = try PersistentJSONFile.read(
            [String].self, from: root.appendingPathComponent("admissions.json"), missing: [])
        #expect(records.count == 14)
        #expect(
            records.allSatisfy {
                if case .done = $0.status { return true }; return false
            })
        #expect(admissions.count == 14)
        #expect(Set(admissions).count == 14)
        let activity = try PersistentJSONFile.read(
            ActivityFixture.self, from: file.appendingPathExtension("activity.json"),
            missing: ActivityFixture(generation: nil, active: [], logs: [:]))
        #expect(activity.active.isEmpty)
        #expect(Set(activity.logs.keys) == Set(records.map { $0.id.uuidString }))
        #expect(activity.logs.values.reduce(0) { $0 + $1.utf8.count } <= 256_000)
    }

    @Test func staleRestartStateIsRecoveredOnlyBySchedulerOwner() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("downloads.json")
        let stale = MusicHistory.DownloadRecord(
            url: URL(string: "https://example.invalid/stale")!, status: .resolving,
            outputFilename: nil, createdAt: Date(), kind: .audio)
        try MusicHistory.DownloadQueue.save([stale], to: file)
        let lease = try #require(
            try PersistentFileLease.acquire(at: file.appendingPathExtension("scheduler.lock")))
        let worker = MusicHistory.DownloadWorker(
            file: file, executable: { URL(fileURLWithPath: "/synthetic/downloader") },
            runCommand: { _, _ in throw CancellationError() })
        try await worker.start()
        #expect(try MusicHistory.DownloadQueue.read(from: file).first?.status == .resolving)
        await worker.stop()
        withExtendedLifetime(lease) {}
        let unlocked = root.appendingPathComponent("unlocked.json")
        try MusicHistory.DownloadQueue.save([stale], to: unlocked)
        let replacement = DownloadsHistory.DownloadWorker(
            file: unlocked, executable: { URL(fileURLWithPath: "/synthetic/downloader") },
            runCommand: { _, _ in throw CancellationError() })
        try await replacement.start()
        #expect(try DownloadsHistory.DownloadQueue.read(from: unlocked).first?.canRetry == true)
        await replacement.stop()
    }

    @Test(arguments: [true, false])
    func eitherObserverProjectsSharedBlockedFlightsAndBoundedLogs(musicFirst: Bool) async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("downloads.json")
        let gate = AttemptGate(root: root)
        let scheduler = HistoryOwner(music: musicFirst, file: file, gate: gate)
        let observer = HistoryOwner(music: !musicFirst, file: file, gate: gate)
        try await scheduler.start()
        var ids: [UUID] = []
        for _ in 0..<3 { ids.append(try await observer.enqueue(root: root)) }
        await scheduler.refresh()
        await gate.waitForStart(3)
        await scheduler.refresh()
        try await observer.start()
        #expect(await observer.running() == 3)
        #expect(await scheduler.running() == 3)
        let initial = await observer.logs()
        #expect(Set(initial.keys) == Set(ids.map { $0.uuidString }))
        #expect(initial.values.allSatisfy { $0.contains("synthetic attempt") })
        #expect(initial.values.allSatisfy { $0.utf8.count <= 64_000 })
        #expect(initial.values.reduce(0) { $0 + $1.utf8.count } <= 256_000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for iteration in 0..<40 {
                group.addTask {
                    if iteration.isMultiple(of: 2) {
                        await gate.emit("fixture log batch \(iteration)")
                        await scheduler.refresh()
                    } else {
                        let logs = await observer.logs()
                        #expect(logs.values.allSatisfy { $0.utf8.count <= 64_000 })
                        #expect(logs.values.reduce(0) { $0 + $1.utf8.count } <= 256_000)
                        #expect(await observer.running() == 3)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await observer.logs() == scheduler.logs())
        await gate.release(1)
        await gate.release(2)
        await gate.release(3)
        await scheduler.waitForIdle()
        #expect(await observer.running() == 0)
        #expect(await observer.logs().count == 3)
        await scheduler.stop()
        await observer.stop()
        let replacement = HistoryOwner(music: !musicFirst, file: file, gate: gate)
        try await replacement.start()
        #expect(await replacement.running() == 0)
        #expect(await replacement.logs().count == 3)
        #expect(await gate.admissions == 3)
        await replacement.stop()
    }

    @Test func staleSchedulerActivityDoesNotInventActiveWorkAndCorruptCacheRecovers() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("downloads.json")
        let stale = MusicHistory.DownloadRecord(
            url: URL(string: "https://example.invalid/stale-activity")!, status: .resolving,
            outputFilename: nil, createdAt: Date(), kind: .audio)
        try MusicHistory.DownloadQueue.save([stale], to: file)
        let activity = file.appendingPathExtension("activity.json")
        let value = ActivityFixture(
            generation: UUID(), active: [stale.id],
            logs: [stale.id.uuidString: "synthetic prior log"])
        _ = try PersistentJSONFile.update(ActivityFixture.self, at: activity, missing: value) {
            $0 = value
        }
        var lease = try PersistentFileLease.acquire(
            at: file.appendingPathExtension("scheduler.lock"))
        #expect(lease != nil)
        let observer = DownloadsHistory.DownloadWorker(file: file, executable: { nil })
        #expect(await observer.snapshot().running == 1)
        withExtendedLifetime(lease) {}
        lease = nil
        #expect(await observer.snapshot().running == 0)
        #expect(await observer.snapshot().logs[stale.id.uuidString] == "synthetic prior log")
        try Data("invalid synthetic activity".utf8).write(to: activity, options: .atomic)
        #expect(await observer.snapshot().problem != nil)
        let gate = AttemptGate(root: root)
        let replacement = HistoryOwner(music: true, file: file, gate: gate)
        try await replacement.start()
        #expect(await replacement.state(stale.id) == "interrupted")
        #expect(await replacement.running() == 0)
        let recovered = try PersistentJSONFile.read(
            ActivityFixture.self, from: activity, missing: value)
        #expect(recovered.active.isEmpty)
        #expect(recovered.logs.isEmpty)
        #expect(await observer.snapshot().problem == nil)
        await replacement.stop()
        await observer.stop()
    }

    @Test(arguments: [true, false], [true, false])
    func acceptedObserverRetrySurvivesOldAttemptDrain(musicFirst: Bool, stop: Bool) async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("downloads.json")
        let gate = AttemptGate(root: root)
        let enabled = HistoryFlag()
        let scheduler = HistoryOwner(music: musicFirst, file: file, gate: gate, enabled: enabled)
        let observerEnabled = HistoryFlag()
        observerEnabled.set(false)
        let observer = HistoryOwner(
            music: !musicFirst, file: file, gate: gate, enabled: observerEnabled)
        try await scheduler.start()
        let id = try await observer.enqueue(root: root)
        await scheduler.refresh()
        await gate.waitForStart(1)
        try await observer.start()
        try await observer.cancel(id)
        try await observer.retry(id)
        #expect(await observer.state(id) == "queued")
        let shutdown: Task<Void, Never>?
        if stop {
            shutdown = Task { await scheduler.stop() }
        } else {
            shutdown = nil
            enabled.set(false)
            await scheduler.refresh()
        }
        await gate.waitForCancellation(1)
        #expect(await observer.running() == 1)
        #expect(await scheduler.running() == 1)
        #expect(await scheduler.state(id) == "queued")
        #expect(await observer.state(id) == "queued")
        await observer.refresh()
        #expect(await gate.admissions == 1)
        await gate.release(1)
        if let shutdown { await shutdown.value } else { await scheduler.waitForIdle() }
        #expect(await observer.state(id) == "queued")
        observerEnabled.set(true)
        await observer.refresh()
        await gate.waitForStart(2)
        #expect(await gate.admissions == 2)
        #expect(await gate.maximumActive == 1)
        if !stop {
            enabled.set(true)
            await scheduler.refresh()
            #expect(await gate.admissions == 2)
        }
        await gate.release(2)
        await observer.waitForIdle()
        #expect(await observer.state(id) == "done")
        #expect(await gate.admissions == 2)
        #expect(try MusicHistory.DownloadQueue.read(from: file).count == 1)
        await scheduler.stop()
        await observer.stop()
    }

    private func environment(owner: String, root: URL, identifier: String = "com.pulkit.edith")
        -> [String: String]
    {
        [
            "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": owner,
            "EDITH_EXTENSION_DATA_ROOT": root.appendingPathComponent("Data/\(owner)").path,
        ]
    }

    private func sandbox() throws -> URL {
        let base = try #require(ProcessInfo.processInfo.environment["HISTORY_FIXTURE_ROOT"])
        let root = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(
            "history-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await predicate())
    }
}

private actor FakeRunner {
    let root: URL
    var started: [String] = []
    var maximumActive = 0
    var duplicateWhileActive = false
    private var active: Set<String> = []
    private var released: Set<String> = []
    private var allReleased = false

    init(root: URL) { self.root = root }
    func release(_ name: String) { released.insert(name) }
    func releaseAll() { allReleased = true }

    func run(_ name: String, line: @escaping @Sendable (String) -> Void) async throws
        -> CLICommandResult
    {
        line("[download] 10.0% of")
        duplicateWhileActive = duplicateWhileActive || active.contains(name)
        active.insert(name)
        started.append(name)
        maximumActive = max(maximumActive, active.count)
        defer { active.remove(name) }
        while !allReleased && !released.contains(name) {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        let output = root.appendingPathComponent(URL(string: name)!.lastPathComponent + ".m4a")
        try Data("synthetic output".utf8).write(to: output)
        return CLICommandResult(terminationStatus: 0, output: output.path + "\n")
    }
}

private final class HistoryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    var value: Bool { lock.withLock { enabled } }
    func set(_ value: Bool) { lock.withLock { enabled = value } }
}

private enum HistoryOwner: Sendable {
    case music(MusicHistory.DownloadWorker)
    case downloads(DownloadsHistory.DownloadWorker)

    init(music: Bool, file: URL, gate: AttemptGate, enabled: HistoryFlag = HistoryFlag()) {
        let run:
            @Sendable (CLICommandRequest, @escaping @Sendable (String) -> Void) async throws
                -> CLICommandResult = { _, line in try await gate.run(line: line) }
        if music {
            self = .music(
                MusicHistory.DownloadWorker(
                    file: file, executable: { URL(fileURLWithPath: "/synthetic/downloader") },
                    isEnabled: { enabled.value }, runCommand: run))
        } else {
            self = .downloads(
                DownloadsHistory.DownloadWorker(
                    file: file, executable: { URL(fileURLWithPath: "/synthetic/downloader") },
                    isEnabled: { enabled.value }, runCommand: run))
        }
    }

    func start() async throws {
        switch self {
        case .music(let worker): try await worker.start()
        case .downloads(let worker): try await worker.start()
        }
    }

    func refresh() async {
        switch self {
        case .music(let worker): await worker.refresh()
        case .downloads(let worker): await worker.refresh()
        }
    }

    func stop() async {
        switch self {
        case .music(let worker): await worker.stop()
        case .downloads(let worker): await worker.stop()
        }
    }

    func enqueue(root: URL) async throws -> UUID {
        let url = URL(string: "https://example.invalid/blocked-attempt")!
        switch self {
        case .music(let worker):
            return try await worker.mutate(
                .enqueue(
                    urls: [url], prefix: "", kind: .audio, outputDirectory: root)
            ).added[0].id
        case .downloads(let worker):
            return try await worker.mutate(
                .enqueue(
                    urls: [url], prefix: "", kind: .audio, outputDirectory: root)
            ).added[0].id
        }
    }

    func cancel(_ id: UUID) async throws {
        switch self {
        case .music(let worker):
            _ = try await worker.mutate(.cancel(id: id, includeQueued: true, reason: "fixture"))
        case .downloads(let worker):
            _ = try await worker.mutate(.cancel(id: id, includeQueued: true, reason: "fixture"))
        }
    }

    func retry(_ id: UUID) async throws {
        switch self {
        case .music(let worker):
            #expect(try await worker.mutate(.retry(id: id, all: false)).changed == 1)
        case .downloads(let worker):
            #expect(try await worker.mutate(.retry(id: id, all: false)).changed == 1)
        }
    }

    func running() async -> Int {
        switch self {
        case .music(let worker): return await worker.snapshot().running
        case .downloads(let worker): return await worker.snapshot().running
        }
    }

    func logs() async -> [String: String] {
        switch self {
        case .music(let worker): return await worker.snapshot().logs
        case .downloads(let worker): return await worker.snapshot().logs
        }
    }

    func state(_ id: UUID) async -> String? {
        switch self {
        case .music(let worker): return await worker.snapshot().records.first { $0.id == id }?.state
        case .downloads(let worker):
            return await worker.snapshot().records.first { $0.id == id }?.state
        }
    }

    func waitForIdle() async {
        switch self {
        case .music(let worker):
            guard let values = try? await worker.values() else {
                Issue.record("Missing stream"); return
            }
            for await value in values where value.running == 0 { return }
        case .downloads(let worker):
            guard let values = try? await worker.values() else {
                Issue.record("Missing stream"); return
            }
            for await value in values where value.running == 0 { return }
        }
        Issue.record("Stream ended before drain")
    }
}

private actor AttemptGate {
    let root: URL
    private(set) var admissions = 0
    private(set) var maximumActive = 0
    private var active = 0
    private var cancellations: Set<Int> = []
    private var drains: [Int: CheckedContinuation<Void, Never>] = [:]
    private var outputs: [Int: @Sendable (String) -> Void] = [:]
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(root: URL) { self.root = root }

    func waitForStart(_ attempt: Int) async {
        if admissions >= attempt { return }
        await withCheckedContinuation { startWaiters.append((attempt, $0)) }
    }

    func waitForCancellation(_ attempt: Int) async {
        if cancellations.contains(attempt) { return }
        await withCheckedContinuation { cancellationWaiters.append((attempt, $0)) }
    }

    func release(_ attempt: Int) { drains.removeValue(forKey: attempt)?.resume() }

    func emit(_ line: String) { for output in outputs.values { output(line) } }

    private func cancelled(_ attempt: Int) {
        cancellations.insert(attempt)
        let ready = cancellationWaiters.filter { $0.0 == attempt }
        cancellationWaiters.removeAll { $0.0 == attempt }
        for (_, continuation) in ready { continuation.resume() }
    }

    func run(line: @escaping @Sendable (String) -> Void) async throws -> CLICommandResult {
        admissions += 1
        let attempt = admissions
        active += 1
        maximumActive = max(maximumActive, active)
        outputs[attempt] = line
        defer { active -= 1; outputs[attempt] = nil }
        for _ in 0..<30 { line(String(repeating: "x", count: 4_000)) }
        line("[download] 10.0% of synthetic attempt \(attempt)")
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                drains[attempt] = continuation
                let ready = startWaiters.filter { $0.0 <= admissions }
                startWaiters.removeAll { $0.0 <= admissions }
                for (_, waiter) in ready { waiter.resume() }
            }
        } onCancel: {
            Task { await self.cancelled(attempt) }
        }
        try Task.checkCancellation()
        let output = root.appendingPathComponent("attempt-\(attempt).m4a")
        try Data("synthetic output".utf8).write(to: output)
        return CLICommandResult(terminationStatus: 0, output: output.path + "\n")
    }
}

private struct ActivityFixture: Codable {
    var generation: UUID?
    var active: [UUID]
    var logs: [String: String]
}
