import EdithExtensionSupport
import Foundation
import Testing

@testable import ClipboardExtension

@Suite struct ClipboardServiceTests {
    @Test func capturesAndCloudImportsPreserveConcurrentEntriesAndMutationsThroughOwnedService()
        async throws
    {
        let fixture = try ClipboardArchiveFixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        let client = ClipboardClient(service: service)
        let initial = fixture.capture("initial")
        _ = try await client.capture(initial)
        let cloudRoot = fixture.root.appendingPathComponent("cloud")
        let cloud = ClipboardArchive(root: cloudRoot)
        let imported = fixture.capture("cloud")
        _ = try cloud.capture(imported, maxItems: 200, maxBytes: 1000, maxAge: nil)
        let cloudEntry = try #require(cloud.snapshot(.init()).entries.first)
        let blobName = cloudEntry.sha256 + "." + cloudEntry.ext
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                let capture = fixture.capture("capture-\(index)")
                group.addTask { _ = try await client.capture(capture) }
            }
            group.addTask { _ = try await client.mutate(.init(.pin, ids: [initial.id])) }
            group.addTask {
                try fixture.archive.restoreBlob(
                    from: cloudRoot.appendingPathComponent("blobs/" + blobName), name: blobName)
                try fixture.archive.mergeAvailableCloudEntries(
                    from: cloudRoot.appendingPathComponent("index.jsonl"))
            }
            try await group.waitForAll()
        }
        let entries = try await client.entries()
        #expect(entries.count == 12)
        #expect(entries.first(where: { $0.id == initial.id })?.pinned == true)
        #expect(entries.contains(where: { $0.id == imported.id }))
        for entry in entries {
            #expect(try await client.blob(id: entry.id).data.count == entry.size)
        }
        #expect(try await client.stats().count == 12)
        await service.stop()
    }

    @Test func acknowledgedCapturesSurviveRestartAndRetriesPreserveIdentityAndPins() async throws {
        let fixture = try ClipboardArchiveFixture()
        defer { fixture.cleanup() }
        let capture = fixture.capture("replay", at: Date(timeIntervalSince1970: 1000.25))
        let service = fixture.service()
        let client = ClipboardClient(service: service)
        #expect(try await client.capture(capture).changed == 1)
        _ = try await client.mutate(.init(.pin, ids: [capture.id]))
        await service.stop()
        let restarted = fixture.service()
        let replay = ClipboardClient(service: restarted)
        #expect(try await replay.capture(capture).changed == 0)
        let later = fixture.capture("replay", at: Date(timeIntervalSince1970: 2000))
        _ = try await replay.capture(later)
        let entries = try await replay.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.id == capture.id)
        #expect(entries.first?.pinned == true)
        #expect(entries.first?.createdAt == Date(timeIntervalSince1970: 1000))
        #expect(entries.first?.lastCopiedAt == Date(timeIntervalSince1970: 2000))
        await restarted.stop()
    }

    @Test func failedBlobWriteNeverCreatesAnIndexRecordAndPreservesExistingHistory() async throws {
        let fixture = try ClipboardArchiveFixture()
        defer { fixture.cleanup() }
        _ = try fixture.archive.capture(
            fixture.capture("kept"), maxItems: 200, maxBytes: 1000, maxAge: nil)
        let before = try Data(contentsOf: fixture.index)
        let failing = ClipboardArchive(
            root: fixture.archive.root,
            writeBlob: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let service = fixture.service(archive: failing)
        let client = ClipboardClient(service: service)
        await #expect(throws: Error.self) { try await client.capture(fixture.capture("rejected")) }
        #expect(try Data(contentsOf: fixture.index) == before)
        #expect(try await client.entries().count == 1)
        await service.stop()
    }

    @Test func malformedIndexesAndSymlinkBlobsAreRejectedWithoutReplacingHistory() throws {
        let fixture = try ClipboardArchiveFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.archive.root, withIntermediateDirectories: true)
        let corrupt = Data("not a clipboard entry\n".utf8)
        try corrupt.write(to: fixture.index)
        #expect(throws: Error.self) {
            try fixture.archive.capture(
                fixture.capture("rejected"), maxItems: 200, maxBytes: 1000, maxAge: nil)
        }
        #expect(try Data(contentsOf: fixture.index) == corrupt)
        try FileManager.default.removeItem(at: fixture.index)
        let target = fixture.root.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: target)
        let capture = fixture.capture("rejected")
        let blobs = fixture.archive.root.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let path = blobs.appendingPathComponent(
            ClipboardRepository.sha256Hex(capture.data) + ".txt")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        #expect(throws: Error.self) {
            try fixture.archive.capture(capture, maxItems: 200, maxBytes: 1000, maxAge: nil)
        }
        #expect(try Data(contentsOf: target) == Data("outside".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.index.path))
    }

    @Test func retentionAndConfirmedDeletionPreservePinsAndLaterCaptures() throws {
        let fixture = try ClipboardArchiveFixture()
        defer { fixture.cleanup() }
        let first = fixture.capture("first", at: Date(timeIntervalSince1970: 1000))
        _ = try fixture.archive.capture(first, maxItems: 1, maxBytes: 1000, maxAge: nil)
        _ = try fixture.archive.mutate(.init(.pin, ids: [first.id]))
        let second = fixture.capture("second", at: Date(timeIntervalSince1970: 2000))
        _ = try fixture.archive.capture(second, maxItems: 1, maxBytes: 1000, maxAge: nil)
        let preview = try fixture.archive.snapshot(.init()).entries.map(\.id)
        let third = fixture.capture("third", at: Date(timeIntervalSince1970: 3000))
        _ = try fixture.archive.capture(third, maxItems: 1, maxBytes: 1000, maxAge: nil)
        #expect(try fixture.archive.snapshot(.init()).entries.count == 2)
        #expect(throws: Error.self) { try fixture.archive.payload(id: second.id) }
        _ = try fixture.archive.mutate(.init(.delete, ids: preview))
        #expect(try fixture.archive.snapshot(.init()).entries.map(\.id) == [third.id])
        #expect(try fixture.archive.payload(id: third.id).data == third.data)
    }

    @Test func snapshotPagesRejectMixedRevisionsAndRequestsStayBounded() throws {
        let fixture = try ClipboardArchiveFixture()
        defer { fixture.cleanup() }
        _ = try fixture.archive.capture(
            fixture.capture("first"), maxItems: 200, maxBytes: 1000, maxAge: nil)
        let first = try fixture.archive.snapshot(.init(limit: 1))
        _ = try fixture.archive.capture(
            fixture.capture("second"), maxItems: 200, maxBytes: 1000, maxAge: nil)
        #expect(
            throws: ClipboardServiceError(.unavailable, ClipboardServiceOperation.changedDuringRead)
        ) {
            try fixture.archive.snapshot(.init(offset: 1, revision: first.revision))
        }
        #expect(throws: Error.self) { try fixture.archive.snapshot(.init(limit: 513)) }
        #expect(throws: Error.self) {
            try fixture.archive.capture(
                fixture.capture(String(repeating: "a", count: 1001)), maxItems: 200, maxBytes: 1000,
                maxAge: nil)
        }
        #expect(try fixture.archive.snapshot(.init()).total == 2)
    }

    @Test func snapshotsRunWhileACaptureIsBlocked() async throws {
        let fixture = try ClipboardArchiveFixture()
        defer { fixture.cleanup() }
        let gate = ClipboardWriteGate()
        let archive = ClipboardArchive(root: fixture.archive.root) { data, url in
            gate.wait()
            try ClipboardFiles.write(data, to: url)
        }
        let service = fixture.service(archive: archive)
        let capture = Task {
            try await service.perform(
                operation: ClipboardServiceOperation.capture,
                payload: try ClipboardMessage.encode(fixture.capture("slow")))
        }
        try await wait { gate.started }
        let first = Task {
            try await service.perform(
                operation: ClipboardServiceOperation.snapshot,
                payload: try ClipboardMessage.encode(ClipboardSnapshotRequest()))
        }
        let second = Task {
            try await service.perform(
                operation: ClipboardServiceOperation.snapshot,
                payload: try ClipboardMessage.encode(ClipboardSnapshotRequest()))
        }
        _ = try await first.value
        _ = try await second.value
        #expect(!capture.isCancelled)
        gate.release()
        _ = try await capture.value
    }

    @Test func shutdownCancelsQueuedRequestsAndAnUncommittedCapture() async throws {
        let fixture = try ClipboardArchiveFixture()
        defer { fixture.cleanup() }
        let gate = ClipboardWriteGate()
        let archive = ClipboardArchive(root: fixture.archive.root) { data, url in
            gate.wait()
            try ClipboardFiles.write(data, to: url)
        }
        let service = fixture.service(archive: archive)
        defer { gate.release() }
        let client = ClipboardClient(service: service)
        let capture = Task { try await client.capture(fixture.capture("cancelled")) }
        try await wait { gate.started }
        let reads = (0..<15).map { index in
            Task { try await client.capture(fixture.capture("queued-\(index)")) }
        }
        try await wait { await service.activeRequests == ClipboardService.maximumRequests }
        await #expect(
            throws: ClipboardServiceError(.unavailable, "The clipboard request queue is full.")
        ) {
            try await client.snapshot()
        }
        let stopping = Task { await service.stop() }
        try await Task.sleep(for: .milliseconds(20))
        gate.release()
        await stopping.value
        await #expect(throws: Error.self) { try await capture.value }
        for read in reads { await #expect(throws: Error.self) { try await read.value } }
        #expect(!FileManager.default.fileExists(atPath: fixture.index.path))
        #expect(await service.activeRequests == 0)
        await #expect(throws: Error.self) { try await client.snapshot() }
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClipboardServiceError(.failed, "The clipboard fixture timed out.")
    }
}

private final class ClipboardArchiveFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clipboard-archive-" + UUID().uuidString)
    let suite = "clipboard-archive-" + UUID().uuidString
    let defaults: UserDefaults
    let archive: ClipboardArchive
    var index: URL { archive.root.appendingPathComponent("index.jsonl") }

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        archive = ClipboardArchive(root: root.appendingPathComponent("local"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func service(archive: ClipboardArchive? = nil) -> ClipboardService {
        ClipboardService(archive: archive ?? self.archive, defaults: defaults, changed: {})
    }

    func capture(_ text: String, at date: Date = Date()) -> ClipboardCapture {
        ClipboardCapture(
            payload: ClipboardPayload(
                data: Data(text.utf8), types: ["public.utf8-plain-text"], ext: "txt", preview: text),
            sourceApp: "Fixture", sourceBundleID: "fixture.clipboard", capturedAt: date)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ClipboardWriteGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var released = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return waiting }

    func wait() {
        condition.lock()
        waiting = true
        while !released { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
