import Darwin
import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct ClipboardLargeHistoryTests {
    @Test func existingHistorySurvivesRetentionCaptureAndRevisionPagingOverXPC() async throws {
        let fixture = try LargeClipboardFixture()
        defer { fixture.cleanup() }
        let entries = try fixture.seed()
        let before = try Data(contentsOf: fixture.index)
        let blobs = try fixture.blobVersions()
        await fixture.start()
        do {
            let result = try fixture.archive.applyRetention(maxItems: 50_000_000, maxAge: nil)
            #expect(result.changed == 0)
            #expect(try Data(contentsOf: fixture.index) == before)
            #expect(try fixture.blobVersions() == blobs)
            #expect(Set(try await fixture.client.entries().map(\.id)) == Set(entries.map(\.id)))
            #expect(try await fixture.client.stats().count == 4138)
            #expect(try fixture.archive.inspect().missingPayloads == 0)
            let page = try await fixture.client.snapshot(.init(offset: 4097, limit: 512))
            #expect(page.total == 4138)
            #expect(page.entries.count == 41)
            for entry in entries.prefix(6) {
                #expect(try fixture.archive.entry(id: entry.id) == entry)
                await #expect(throws: Error.self) { try await fixture.client.blob(id: entry.id) }
            }
            let capture = fixture.capture("new synthetic capture")
            #expect(try await fixture.client.capture(capture).total == 4139)
            let after = try await fixture.client.entries()
            #expect(Set(entries.map(\.id)).isSubset(of: Set(after.map(\.id))))
            #expect(after.contains { $0.id == capture.id })
            await #expect(
                throws: AgentError(.unavailable, AgentClipboardOperation.changedDuringRead)
            ) {
                try await fixture.client.snapshot(.init(offset: 4097, revision: page.revision))
            }
            #expect(try await fixture.client.snapshot(.init(offset: 4139)).entries.isEmpty)
            await #expect(throws: Error.self) {
                try await fixture.client.snapshot(.init(offset: Int.max))
            }
            await #expect(throws: Error.self) {
                try await fixture.client.snapshot(.init(limit: 513))
            }
            for (name, version) in blobs { #expect(try fixture.blobVersions()[name] == version) }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func explicitRetentionPreservesLargePinnedRecordsAndSharedPayloads() throws {
        let fixture = try LargeClipboardFixture()
        defer { fixture.cleanup() }
        let entries = try fixture.seed(pinned: Set(0..<6))
        let blobs = try fixture.blobVersions()
        let result = try fixture.archive.applyRetention(
            maxItems: 2, maxAge: 2.5,
            now: #require(entries.last).lastCopiedAt.addingTimeInterval(0.5))
        #expect(result.total == 8)
        #expect(result.changed == 4130)
        let kept = try fixture.archive.snapshot(.init()).entries
        #expect(
            Set(kept.map(\.id)) == Set((Array(entries.prefix(6)) + entries.suffix(2)).map(\.id)))
        #expect(try fixture.blobVersions() == blobs)
        #expect(
            try fixture.archive.payload(id: #require(entries.last).id).data == fixture.smallPayload)
    }

    @Test func malformedOversizedAndSymlinkIndexesNeverPublishOrPrune() throws {
        let fixture = try LargeClipboardFixture()
        defer { fixture.cleanup() }
        _ = try fixture.seed()
        let valid = try Data(contentsOf: fixture.index)
        let blobs = try fixture.blobVersions()
        let invalid = valid + Data("invalid final record\n".utf8)
        try invalid.write(to: fixture.index, options: .atomic)
        #expect(throws: Error.self) { try fixture.archive.applyRetention(maxItems: 0, maxAge: nil) }
        #expect(try Data(contentsOf: fixture.index) == invalid)
        #expect(try fixture.blobVersions() == blobs)
        let oversized = valid + Data(repeating: 10, count: ClipboardArchive.maximumIndexBytes)
        try oversized.write(to: fixture.index, options: .atomic)
        #expect(throws: Error.self) { try fixture.archive.applyRetention(maxItems: 0, maxAge: nil) }
        #expect(try Data(contentsOf: fixture.index) == oversized)
        #expect(try fixture.blobVersions() == blobs)
        let target = fixture.root.appendingPathComponent("outside-index")
        try valid.write(to: target)
        try FileManager.default.removeItem(at: fixture.index)
        try FileManager.default.createSymbolicLink(at: fixture.index, withDestinationURL: target)
        #expect(throws: Error.self) { try fixture.archive.applyRetention(maxItems: 0, maxAge: nil) }
        #expect(try Data(contentsOf: target) == valid)
        #expect(try fixture.blobVersions() == blobs)
    }

    @Test func pinnedHistoryCanExceedTheMutationBatchLimit() throws {
        let fixture = try LargeClipboardFixture()
        defer { fixture.cleanup() }
        _ = try fixture.seed(pinned: Set(0..<4138))
        let before = try Data(contentsOf: fixture.index)
        let blobs = try fixture.blobVersions()
        let result = try fixture.archive.applyRetention(maxItems: 0, maxAge: 1)
        #expect(result.changed == 0)
        #expect(result.total == 4138)
        #expect(try Data(contentsOf: fixture.index) == before)
        #expect(try fixture.blobVersions() == blobs)
    }

    @Test func cancelledRetentionAndConcurrentImportsPreserveExistingHistory() async throws {
        let fixture = try LargeClipboardFixture()
        defer { fixture.cleanup() }
        let entries = try fixture.seed()
        let before = try Data(contentsOf: fixture.index)
        let blobs = try fixture.blobVersions()
        await fixture.start()
        do {
            let descriptor = open(
                fixture.archive.root.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o600)
            #expect(descriptor >= 0)
            defer {
                _ = flock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let task = Task.detached {
                started.continuation.yield(())
                started.continuation.finish()
                return try fixture.archive.applyRetention(maxItems: 50_000_000, maxAge: nil)
            }
            for await _ in started.stream { break }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try Data(contentsOf: fixture.index) == before)
            #expect(try fixture.blobVersions() == blobs)
            #expect(flock(descriptor, LOCK_UN) == 0)
            let cloud = ClipboardArchive(root: fixture.root.appendingPathComponent("cloud"))
            let imported = fixture.capture("synthetic cloud capture")
            _ = try cloud.capture(imported, maxItems: 200, maxBytes: 1000, maxAge: nil)
            let entry = try #require(cloud.snapshot(.init()).entries.first)
            let name = entry.sha256 + "." + entry.ext
            try fixture.archive.restoreBlob(
                from: cloud.root.appendingPathComponent("blobs/" + name), name: name)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try fixture.archive.applyRetention(maxItems: 50_000_000, maxAge: nil)
                }
                group.addTask {
                    try fixture.archive.mergeAvailableCloudEntries(
                        from: cloud.root.appendingPathComponent("index.jsonl"))
                }
                for index in 0..<8 {
                    group.addTask {
                        _ = try await fixture.client.capture(fixture.capture("concurrent-\(index)"))
                    }
                }
                try await group.waitForAll()
            }
            let after = try await fixture.client.entries()
            #expect(after.count == entries.count + 9)
            #expect(Set(entries.map(\.id)).isSubset(of: Set(after.map(\.id))))
            #expect(after.contains { $0.id == imported.id })
            for (name, version) in blobs { #expect(try fixture.blobVersions()[name] == version) }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func payloadAdmissionAndMetadataArithmeticRemainBounded() throws {
        let fixture = try LargeClipboardFixture()
        defer { fixture.cleanup() }
        _ = try fixture.seed(count: 2, largeCount: 0)
        let before = try Data(contentsOf: fixture.index)
        let capture = ClipboardCapture(
            payload: ClipboardPayload(
                data: Data(count: ClipboardArchive.maximumBlobBytes + 1), types: ["public.data"],
                ext: "data", preview: "synthetic oversized capture"),
            sourceApp: nil, sourceBundleID: nil)
        #expect(throws: Error.self) {
            try fixture.archive.capture(
                capture, maxItems: 50_000_000, maxBytes: 100_000_000, maxAge: nil)
        }
        #expect(throws: Error.self) {
            try fixture.archive.mutate(
                .init(.delete, ids: Array(repeating: "synthetic", count: 4097)))
        }
        #expect(try Data(contentsOf: fixture.index) == before)
        let overflow = (0..<2).map {
            fixture.entry(
                number: $0, size: Int.max, hash: String(repeating: "a", count: 64), ext: "data")
        }
        let invalid = Data(ClipboardIndex.encode(overflow).utf8)
        try invalid.write(to: fixture.index, options: .atomic)
        #expect(throws: Error.self) { try fixture.archive.stats() }
        #expect(throws: Error.self) { try fixture.archive.applyRetention(maxItems: 0, maxAge: nil) }
        #expect(try Data(contentsOf: fixture.index) == invalid)
        let full = Data(ClipboardIndex.encode([overflow[0]]).utf8)
        try full.write(to: fixture.index, options: .atomic)
        let blobs = try fixture.blobVersions()
        #expect(throws: Error.self) {
            try fixture.archive.capture(
                fixture.capture("aggregate overflow"), maxItems: 50_000_000,
                maxBytes: 100_000_000, maxAge: nil)
        }
        #expect(try Data(contentsOf: fixture.index) == full)
        #expect(try fixture.blobVersions() == blobs)
    }
}

private final class LargeClipboardFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clipboard-large-" + UUID().uuidString)
    let suite = "clipboard-large-" + UUID().uuidString
    let defaults: UserDefaults
    let archive: ClipboardArchive
    let service: ClipboardService
    let runtime: AgentRuntime
    let listener: AgentRuntimeTestListener
    let client: AgentClipboardClient
    let smallPayload = Data("synthetic shared payload".utf8)
    var index: URL { archive.root.appendingPathComponent("index.jsonl") }

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(50_000_000, forKey: AppStorageKeys.Clipboard.maxItems)
        defaults.set(100_000_000, forKey: AppStorageKeys.Clipboard.maxItemBytes)
        archive = ClipboardArchive(root: root.appendingPathComponent("archive"))
        service = ClipboardService(archive: archive, defaults: defaults, changed: {})
        runtime = AgentRuntime(build: "clipboard-large", store: nil)
        listener = AgentRuntimeTestListener(runtime: runtime)
        client = AgentClipboardClient(client: listener.client())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func seed(count: Int = 4138, largeCount: Int = 6, pinned: Set<Int> = []) throws
        -> [ClipboardEntry]
    {
        let blobs = archive.root.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let smallHash = ClipboardRepository.sha256Hex(smallPayload)
        try smallPayload.write(to: blobs.appendingPathComponent(smallHash + ".txt"))
        let largeSize = ClipboardArchive.maximumBlobBytes + 1
        let largeHash = ClipboardRepository.sha256Hex(Data(count: largeSize))
        for number in 0..<largeCount {
            let url = blobs.appendingPathComponent(largeHash + ".data\(number)")
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(largeSize))
        }
        let entries = (0..<count).map { number in
            entry(
                number: number, size: number < largeCount ? largeSize : smallPayload.count,
                hash: number < largeCount ? largeHash : smallHash,
                ext: number < largeCount ? "data\(number)" : "txt", pinned: pinned.contains(number))
        }
        try Data(ClipboardIndex.encode(entries).utf8).write(to: index)
        return entries
    }

    func entry(number: Int, size: Int, hash: String, ext: String, pinned: Bool = false)
        -> ClipboardEntry
    {
        ClipboardEntry(
            id: "synthetic-\(number)", sha256: hash, types: ["public.data"], ext: ext,
            sourceApp: "Fixture", sourceBundleID: "fixture.clipboard",
            createdAt: Date(timeIntervalSince1970: Double(1000 + number)),
            size: size, preview: "Synthetic entry", pinned: pinned)
    }

    func capture(_ text: String) -> ClipboardCapture {
        ClipboardCapture(
            payload: ClipboardPayload(
                data: Data(text.utf8), types: ["public.data"], ext: "txt", preview: text),
            sourceApp: "Fixture", sourceBundleID: "fixture.clipboard")
    }

    func blobVersions() throws -> [String: String] {
        let blobs = archive.root.appendingPathComponent("blobs")
        return try Dictionary(
            uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: blobs.path).map {
                name in
                let values = try FileManager.default.attributesOfItem(
                    atPath: blobs.appendingPathComponent(name).path)
                let inode = try #require(values[.systemFileNumber] as? NSNumber)
                let size = try #require(values[.size] as? NSNumber)
                let modified = try #require(values[.modificationDate] as? Date)
                return (name, "\(inode)|\(size)|\(modified)")
            })
    }

    func start() async {
        await service.register(on: runtime)
    }

    func close() async {
        await runtime.shutdown()
        listener.stop()
    }

    func cleanup() {
        listener.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
