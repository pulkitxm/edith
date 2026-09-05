import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentClipboardTests {
    @Test func capturesAndCloudImportsPreserveConcurrentEntriesAndMutationsOverXPC() async throws {
        let fixture = try ClipboardArchiveFixture()
        defer { fixture.cleanup() }
        let runtime = AgentRuntime(build: "clipboard-fixture", store: nil)
        let service = fixture.service()
        await service.register(on: runtime)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = AgentClipboardClient(client: listener.client())
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
        await runtime.shutdown()
    }

    @Test func acknowledgedCapturesSurviveRestartAndRetriesPreserveIdentityAndPins() async throws {
        let fixture = try ClipboardArchiveFixture()
        defer { fixture.cleanup() }
        let capture = fixture.capture("replay", at: Date(timeIntervalSince1970: 1000.25))
        let runtime = AgentRuntime(build: "clipboard-first", store: nil)
        await fixture.service().register(on: runtime)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        let client = AgentClipboardClient(client: listener.client())
        #expect(try await client.capture(capture).changed == 1)
        _ = try await client.mutate(.init(.pin, ids: [capture.id]))
        await runtime.shutdown()
        listener.stop()
        let restarted = AgentRuntime(build: "clipboard-restarted", store: nil)
        await fixture.service().register(on: restarted)
        let replayListener = AgentRuntimeTestListener(runtime: restarted)
        defer { replayListener.stop() }
        let replay = AgentClipboardClient(client: replayListener.client())
        #expect(try await replay.capture(capture).changed == 0)
        let later = fixture.capture("replay", at: Date(timeIntervalSince1970: 2000))
        _ = try await replay.capture(later)
        let entries = try await replay.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.id == capture.id)
        #expect(entries.first?.pinned == true)
        #expect(entries.first?.createdAt == Date(timeIntervalSince1970: 1000))
        #expect(entries.first?.lastCopiedAt == Date(timeIntervalSince1970: 2000))
        await restarted.shutdown()
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
        let runtime = AgentRuntime(build: "clipboard-write-failure", store: nil)
        await fixture.service(archive: failing).register(on: runtime)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = AgentClipboardClient(client: listener.client())
        await #expect(throws: Error.self) { try await client.capture(fixture.capture("rejected")) }
        #expect(try Data(contentsOf: fixture.index) == before)
        #expect(try await client.entries().count == 1)
        await runtime.shutdown()
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
        #expect(throws: AgentError(.unavailable, AgentClipboardOperation.changedDuringRead)) {
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

    @Test func shutdownCancelsQueuedRequestsAndAnUncommittedCapture() async throws {
        let fixture = try ClipboardArchiveFixture()
        defer { fixture.cleanup() }
        let gate = ClipboardWriteGate()
        let archive = ClipboardArchive(root: fixture.archive.root) { data, url in
            gate.wait()
            try UsageDataFiles.write(data, to: url)
        }
        let service = fixture.service(archive: archive)
        let runtime = AgentRuntime(build: "clipboard-stop", store: nil)
        await service.register(on: runtime)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop(); gate.release() }
        let client = AgentClipboardClient(client: listener.client())
        let capture = Task { try await client.capture(fixture.capture("cancelled")) }
        try await wait { gate.started }
        let reads = (0..<15).map { _ in Task { try await client.snapshot() } }
        try await wait { await service.activeRequests == ClipboardService.maximumRequests }
        await #expect(throws: AgentError(.unavailable, "The clipboard request queue is full.")) {
            try await client.snapshot()
        }
        let stopping = Task { await runtime.shutdown() }
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
        throw AgentError(.failed, "The clipboard fixture timed out.")
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
