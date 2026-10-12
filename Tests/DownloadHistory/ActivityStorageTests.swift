import DownloadsHistory
import EdithExtensionSupport
import Foundation
import MusicHistory
import Testing

@Suite struct ActivityStorageTests {
    @Test func activityLifecycleBoundsRetentionAndCountsSharedFilesOnce() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["HISTORY_FIXTURE_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("activity-storage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Edith/data/downloads.json")
        let records = (0..<40).map { index in
            MusicHistory.DownloadRecord(
                url: URL(string: "https://example.invalid/retained\(index)")!,
                status: .done("synthetic.m4a"), outputFilename: nil,
                createdAt: Date(timeIntervalSince1970: Double(index)), kind: .audio)
        }
        try MusicHistory.DownloadQueue.save(records, to: file)
        let activityFile = file.appendingPathExtension("activity.json")
        let old = StorageActivity(
            generation: UUID(), active: [],
            logs: Dictionary(
                uniqueKeysWithValues: records.map {
                    ($0.id.uuidString, String(repeating: "x", count: 64_000))
                }))
        _ = try PersistentJSONFile.update(StorageActivity.self, at: activityFile, missing: old) {
            $0 = old
        }
        let worker = MusicHistory.DownloadWorker(
            file: file, executable: { URL(fileURLWithPath: "/synthetic/downloader") },
            runCommand: { _, _ in
                Issue.record("No queued work exists"); throw CancellationError()
            })
        try await worker.start()
        let bounded = try PersistentJSONFile.read(
            StorageActivity.self, from: activityFile, missing: old)
        #expect(bounded.active.isEmpty)
        #expect(bounded.logs.count <= 32)
        #expect(bounded.logs.values.allSatisfy { $0.utf8.count <= 64_000 })
        #expect(bounded.logs.values.reduce(0) { $0 + $1.utf8.count } == 256_000)
        let files = [
            file, file.appendingPathExtension("lock"),
            file.appendingPathExtension("scheduler.lock"), activityFile,
            activityFile.appendingPathExtension("lock"),
        ]
        var scopes = [
            HostStorageScope(id: "usage", root: root.appendingPathComponent("Edith/data"))
        ]
        for owner in ["music", "downloads"] {
            let leaves = try #require(ExtensionData.productionLeaves[owner])
            for sharedFile in files {
                let relative = "data/" + sharedFile.lastPathComponent
                #expect(leaves.contains(relative))
                scopes.append(HostStorageScope(id: owner + ":" + relative, root: sharedFile))
            }
        }
        let measurement = try HostStorageAccounting.scan(scopes: scopes)
        let expected = try files.reduce(Int64(0)) { $0 + Int64(try Data(contentsOf: $1).count) }
        #expect(measurement.total.complete)
        #expect(measurement.total.logical == expected)
        #expect(measurement.bytes["music:data/downloads.json.activity.json"]?.logical == 0)
        #expect(
            measurement.bytes["downloads:data/downloads.json.activity.json"]?.logical
                == Int64(try Data(contentsOf: activityFile).count))
        let observer = DownloadsHistory.DownloadWorker(file: file, executable: { nil })
        _ = try await observer.mutate(.clear(includeActive: false))
        await worker.refresh()
        #expect(await observer.snapshot().logs.isEmpty)
        #expect(
            try PersistentJSONFile.read(StorageActivity.self, from: activityFile, missing: old).logs
                .isEmpty)
        await worker.stop()
        await observer.stop()
        #expect(try MusicHistory.DownloadQueue.read(from: file).isEmpty)
    }
}

private struct StorageActivity: Codable {
    var generation: UUID?
    var active: [UUID]
    var logs: [String: String]
}
