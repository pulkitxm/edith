import Foundation
import GRDB
import Testing

@testable import EdithAgent
@testable import EdithHelper
@testable import EdithKit

private struct AttentionDeliveryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var file: URL { root.appendingPathComponent("delivery.json") }

    func event(_ offset: TimeInterval = 0, name: String = "Writing") -> AttentionEvent {
        AttentionEvent(
            startedAt: Date(timeIntervalSince1970: 1_783_000_000).addingTimeInterval(offset),
            duration: 5, source: .application, appName: name, bundleID: "com.example.writing")
    }

    func close() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct AttentionDeliverySpoolTests {
    @Test func drainAndRelaunchPreserveProducerAndMonotonicSequence() async throws {
        let fixture = AttentionDeliveryFixture()
        defer { fixture.close() }
        let spool = AttentionDeliverySpool(file: fixture.file)
        _ = try await spool.append([fixture.event()])
        let first = try #require(try await spool.first())
        try await spool.acknowledge(first)
        let reopened = AttentionDeliverySpool(file: fixture.file)
        _ = try await reopened.append([fixture.event(5)])
        let next = try #require(try await reopened.first())
        #expect(next.producerID == first.producerID)
        #expect(next.sequence == first.sequence + 1)
    }

    @Test func capacityPreservesOldestPendingAndPersistsOverflowCounts() async throws {
        let fixture = AttentionDeliveryFixture()
        defer { fixture.close() }
        let spool = AttentionDeliverySpool(file: fixture.file, maximumEvents: 2)
        let accepted = try await spool.append([
            fixture.event(), fixture.event(5), fixture.event(10),
        ])
        #expect(accepted == 2)
        let reopened = AttentionDeliverySpool(file: fixture.file, maximumEvents: 2)
        let health = try await reopened.health()
        #expect(health.pendingEvents == 2)
        #expect(health.rejectedEvents == 1)
        #expect(health.rejectedDuration == 5)
        #expect(health.lastFailure != nil)
        #expect(try await reopened.first()?.sequence == 1)
    }

    @Test func diskLimitRejectsOversizedSamplesWithoutGrowingTheFile() async throws {
        let fixture = AttentionDeliveryFixture()
        defer { fixture.close() }
        let spool = AttentionDeliverySpool(file: fixture.file, maximumBytes: 2048)
        let accepted = try await spool.append([
            fixture.event(name: String(repeating: "x", count: 4096))
        ])
        #expect(accepted == 0)
        #expect(try Data(contentsOf: fixture.file).count <= 2048)
        #expect(try await spool.health().rejectedEvents == 1)
    }

    @Test func ambiguousDeliveryAndWrongAcknowledgementKeepTheSavedEvent() async throws {
        let fixture = AttentionDeliveryFixture()
        defer { fixture.close() }
        let spool = AttentionDeliverySpool(file: fixture.file)
        _ = try await spool.append([fixture.event()])
        let first = try #require(try await spool.first())
        try await spool.failedDelivery()
        let wrong = AttentionDeliveryRequest(
            producerID: first.producerID, sequence: first.sequence + 1, batch: first.batch)
        await #expect(throws: AgentError.self) { try await spool.acknowledge(wrong) }
        #expect(try await AttentionDeliverySpool(file: fixture.file).first() == first)
    }

    @Test func corruptAndSymbolicStorageArePreservedAndRefused() async throws {
        let fixture = AttentionDeliveryFixture()
        defer { fixture.close() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let corrupt = Data("invalid".utf8)
        try corrupt.write(to: fixture.file)
        await #expect(throws: (any Error).self) {
            _ = try await AttentionDeliverySpool(file: fixture.file).append([fixture.event()])
        }
        #expect(try Data(contentsOf: fixture.file) == corrupt)
        let link = fixture.root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file)
        await #expect(throws: (any Error).self) {
            _ = try await AttentionDeliverySpool(file: link).append([fixture.event()])
        }
        #expect(try Data(contentsOf: fixture.file) == corrupt)
    }
}

@Suite struct AttentionDeliveryReceiptTests {
    @Test func failedEventTransactionCannotAdvanceItsReceipt() throws {
        let fixture = AttentionDeliveryFixture()
        defer { fixture.close() }
        let store = try AgentStore(
            url: fixture.root.appendingPathComponent("store.sqlite"), build: "test")
        defer { try? store.close() }
        let events = AttentionEventStore(store: store)
        let now = fixture.event().startedAt.addingTimeInterval(60)
        try store.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER fail_delivery BEFORE INSERT ON attention_event
                    BEGIN SELECT RAISE(ABORT, 'fixture failure'); END
                    """)
        }
        let request = AttentionDeliveryRequest(
            producerID: UUID(), sequence: 1, batch: AttentionBatch(events: [fixture.event()]))
        #expect(throws: (any Error).self) { try events.deliver(request, now: now) }
        let count = try store.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attention_delivery_receipt")
        }
        #expect(count == 0)
        try store.write { try $0.execute(sql: "DROP TRIGGER fail_delivery") }
        try events.deliver(request, now: now)
        #expect(try events.events(from: now.addingTimeInterval(-61), to: now).count == 1)
    }

    @Test func repeatedDeliveryCannotChargeDurationTwiceAfterCoalescing() throws {
        let fixture = AttentionDeliveryFixture()
        defer { fixture.close() }
        let store = try AgentStore(
            url: fixture.root.appendingPathComponent("store.sqlite"), build: "test")
        defer { try? store.close() }
        let events = AttentionEventStore(store: store)
        let producer = UUID()
        let now = fixture.event().startedAt.addingTimeInterval(60)
        let first = AttentionDeliveryRequest(
            producerID: producer, sequence: 1, batch: AttentionBatch(events: [fixture.event()]))
        let second = AttentionDeliveryRequest(
            producerID: producer, sequence: 2, batch: AttentionBatch(events: [fixture.event(5)]))
        try events.deliver(first, now: now)
        try events.deliver(second, now: now)
        try events.deliver(first, now: now)
        try events.deliver(second, now: now)
        let result = try events.events(from: now.addingTimeInterval(-61), to: now)
        #expect(result.count == 1)
        #expect(result.first?.duration == 10)
    }

    @Test func gapIsRefusedUntilEarlierSequenceCommits() throws {
        let fixture = AttentionDeliveryFixture()
        defer { fixture.close() }
        let store = try AgentStore(
            url: fixture.root.appendingPathComponent("store.sqlite"), build: "test")
        defer { try? store.close() }
        let events = AttentionEventStore(store: store)
        let producer = UUID()
        let now = fixture.event().startedAt.addingTimeInterval(60)
        func request(_ sequence: Int64) -> AttentionDeliveryRequest {
            AttentionDeliveryRequest(
                producerID: producer, sequence: sequence,
                batch: AttentionBatch(events: [fixture.event(Double(sequence - 1) * 5)]))
        }
        try events.deliver(request(1), now: now)
        #expect(throws: AgentError.self) { try events.deliver(request(3), now: now) }
        try events.deliver(request(2), now: now)
        try events.deliver(request(3), now: now)
        #expect(try events.events(from: now.addingTimeInterval(-61), to: now).first?.duration == 15)
    }

    @Test func receiptCardinalityRefusesNewProducersUntilRetentionExpires() throws {
        let fixture = AttentionDeliveryFixture()
        defer { fixture.close() }
        let store = try AgentStore(
            url: fixture.root.appendingPathComponent("store.sqlite"), build: "test")
        defer { try? store.close() }
        let events = AttentionEventStore(store: store)
        let now = fixture.event().startedAt.addingTimeInterval(60)
        try store.write { database in
            for _ in 0..<128 {
                try database.execute(
                    sql: "INSERT INTO attention_delivery_receipt VALUES (?, 1, ?)",
                    arguments: [UUID().uuidString, now])
            }
        }
        let request = AttentionDeliveryRequest(
            producerID: UUID(), sequence: 1, batch: AttentionBatch(events: [fixture.event()]))
        #expect(throws: AgentError.self) { try events.deliver(request, now: now) }
        try events.deliver(request, now: now.addingTimeInterval(366 * 86400))
        let count = try store.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attention_delivery_receipt")
        }
        #expect(count == 1)
    }
}

@MainActor @Suite struct AttentionHeartbeatWriterTests {
    @Test func captureQueueCapacityIncludesTheSampleBeingPrepared() async throws {
        let fixture = AttentionDeliveryFixture()
        defer { fixture.close() }
        let started = AttentionDeliveryGate()
        let release = AttentionDeliveryGate()
        let writer = AttentionHeartbeatWriter(
            spool: AttentionDeliverySpool(file: fixture.file), maximumPending: 1,
            prepare: { sample in
                await started.signal()
                await release.wait()
                return sample.event
            }, deliver: { _ in })
        writer.submit(
            AttentionHeartbeatSample(
                event: fixture.event(), processID: 0, captureWindowTitle: false))
        await started.wait()
        writer.submit(
            AttentionHeartbeatSample(
                event: fixture.event(5), processID: 0, captureWindowTitle: false))
        #expect(writer.queuedSampleCount == 1)
        await release.signal()
        await writer.flush()
        await writer.stop()
        #expect(try await writer.health().rejectedEvents == 1)
    }

    @Test func unavailableDaemonKeepsEventsDurableAcrossWriterRestart() async throws {
        let fixture = AttentionDeliveryFixture()
        defer { fixture.close() }
        let writer = AttentionHeartbeatWriter(
            spool: AttentionDeliverySpool(file: fixture.file), retryDelay: .seconds(3600),
            prepare: { $0.event }, deliver: { _ in throw AgentError(.unavailable, "offline") })
        writer.submit(
            AttentionHeartbeatSample(
                event: fixture.event(), processID: 0, captureWindowTitle: false))
        await writer.flush()
        await writer.stop()
        #expect(writer.isStopped)
        #expect(try await AttentionDeliverySpool(file: fixture.file).health().pendingEvents == 1)
        let recovered = AttentionHeartbeatWriter(
            spool: AttentionDeliverySpool(file: fixture.file), prepare: { $0.event },
            deliver: { _ in })
        await recovered.flush()
        await recovered.stop()
        #expect(try await AttentionDeliverySpool(file: fixture.file).health().pendingEvents == 0)
    }

    @Test func shutdownCancelsNetworkAndPersistsAcceptedSamplesBeforeReturning() async throws {
        let fixture = AttentionDeliveryFixture()
        defer { fixture.close() }
        let started = AttentionDeliveryGate()
        let writer = AttentionHeartbeatWriter(
            spool: AttentionDeliverySpool(file: fixture.file), prepare: { $0.event },
            deliver: { _ in
                await started.signal()
                try await Task.sleep(for: .seconds(3600))
            })
        writer.submit(
            AttentionHeartbeatSample(
                event: fixture.event(), processID: 0, captureWindowTitle: false))
        await started.wait()
        writer.submit(
            AttentionHeartbeatSample(
                event: fixture.event(5), processID: 0, captureWindowTitle: false))
        await writer.stop()
        #expect(writer.isStopped)
        #expect(try await AttentionDeliverySpool(file: fixture.file).health().pendingEvents == 2)
    }
}

private actor AttentionDeliveryGate {
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func signal() { signaled = true; continuation?.resume(); continuation = nil }
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation = $0 }
    }
}
