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
