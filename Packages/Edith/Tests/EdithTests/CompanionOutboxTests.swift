import Foundation
import Testing

@testable import EdithKit

@Suite struct CompanionOutboxTests {
    private func sandbox() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recording(_ name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        try? Data("audio".utf8).write(to: url)
        return url
    }

    @Test func aRecordingThatCannotBeSentIsKeptRatherThanLost() throws {
        let root = sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = recording("memo.wav")
        let kept = try #require(CompanionOutbox.keep(source, in: root))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(CompanionOutbox.waiting(in: root).count == 1)
    }

    @Test func drainingSendsEveryWaitingRecordingAndClearsThem() async throws {
        let root = sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = CompanionOutbox.keep(recording("one.wav"), in: root)
        _ = CompanionOutbox.keep(recording("two.wav"), in: root)
        let result = await CompanionOutbox.drain(in: root) { _, _ in "ingested" }
        #expect(result.sent == 2)
        #expect(result.failed == 0)
        #expect(CompanionOutbox.waiting(in: root).isEmpty)
    }

    @Test func aFailedSendKeepsTheRecordingForNextTime() async throws {
        let root = sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = CompanionOutbox.keep(recording("memo.wav"), in: root)
        struct Offline: Error {}
        let result = await CompanionOutbox.drain(in: root) { _, _ in throw Offline() }
        #expect(result.failed == 1)
        #expect(result.sent == 0)
        #expect(CompanionOutbox.waiting(in: root).count == 1)
    }

    @Test func alreadyKnownRecordingsAreCountedApartFromNewOnes() async throws {
        let root = sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = CompanionOutbox.keep(recording("dupe.wav"), in: root)
        let result = await CompanionOutbox.drain(in: root) { _, _ in "duplicate" }
        #expect(result.duplicates == 1)
        #expect(result.sent == 0)
        #expect(CompanionOutbox.waiting(in: root).isEmpty)
    }

    @Test func theOldestRecordingIsSentFirst() throws {
        let root = sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(CompanionOutbox.keep(recording("first.wav"), in: root))
        let second = try #require(CompanionOutbox.keep(recording("second.wav"), in: root))
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: second.path)
        #expect(
            CompanionOutbox.waiting(in: root).map { $0.url.lastPathComponent }
                == [first.lastPathComponent, second.lastPathComponent])
    }

    @Test func anEmptyOutboxDrainsToNothing() async {
        let root = sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await CompanionOutbox.drain(in: root) { _, _ in "ingested" }
        #expect(result.isEmpty)
        #expect(result.summary.isEmpty)
    }

    @Test func theSummaryReadsAsASentence() {
        let result = CompanionOutboxDrain(sent: 2, duplicates: 1, failed: 1)
        #expect(result.summary == "2 remembered, 1 already known, 1 still waiting")
    }
}
