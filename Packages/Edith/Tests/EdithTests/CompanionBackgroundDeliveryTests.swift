import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct CompanionBackgroundDeliveryTests {
    private let endpoint = URL(string: "http://127.0.0.1:4820")!

    @Test func healthRepairsTheTunnelBeforeRetryingAndDelivering() async throws {
        let events = DeliveryEvents()
        let job = CompanionHealthJob(
            store: nil, isConfigured: { true }, endpoint: { self.endpoint },
            probe: { _ in
                let attempt = await events.probe()
                if attempt == 1 { throw URLError(.cannotConnectToHost) }
                return CompanionHealth(ok: true, checks: [])
            },
            repair: { _ in
                await events.append("repair")
                return true
            },
            deliverOutbox: { _ in await events.append("deliver") })

        let snapshot = try AgentPayload.decode(
            CompanionHealthSnapshot.self, from: try #require(await job.run()))

        #expect(snapshot.reachable)
        #expect(await events.values == ["probe", "repair", "probe", "deliver"])
    }

    @Test func failedRepairPreservesTheFailureAndDoesNotDeliver() async throws {
        let events = DeliveryEvents()
        let job = CompanionHealthJob(
            store: nil, isConfigured: { true }, endpoint: { self.endpoint },
            probe: { _ in
                _ = await events.probe()
                throw URLError(.cannotConnectToHost)
            },
            repair: { _ in
                await events.append("repair")
                return false
            },
            deliverOutbox: { _ in await events.append("deliver") })

        let snapshot = try AgentPayload.decode(
            CompanionHealthSnapshot.self, from: try #require(await job.run()))

        #expect(!snapshot.reachable)
        #expect(snapshot.failure != nil)
        #expect(await events.values == ["probe", "repair"])
    }

    @Test func queuedAudioIsDeliveredByTheHealthJobWithoutACaptureScreen() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("recording payload".utf8)
        let source = directory.appendingPathComponent("source.wav")
        try payload.write(to: source)
        let queue = directory.appendingPathComponent("queue")
        _ = try #require(CompanionOutbox.keep(source, in: queue))
        let events = DeliveryEvents()
        let worker = CompanionOutboxDelivery(
            directory: queue,
            send: { url, item, data in
                #expect(url == self.endpoint)
                #expect(item.name == "source.wav")
                #expect(data == payload)
                await events.append("sent")
                return "ingested"
            }, notify: {})
        let job = CompanionHealthJob(
            store: nil, isConfigured: { true }, endpoint: { self.endpoint },
            probe: { _ in CompanionHealth(ok: true, checks: []) },
            repair: { _ in false },
            deliverOutbox: { url in _ = await worker.drain(endpoint: url) })

        _ = try await job.run()

        #expect(CompanionOutbox.waiting(in: queue).isEmpty)
        #expect(await events.values == ["sent"])
    }

    @Test func failedAudioIsRetriedByASubsequentDaemonPass() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("recording".utf8).write(to: directory.appendingPathComponent("memo.wav"))
        let events = DeliveryEvents()
        let worker = CompanionOutboxDelivery(
            directory: directory,
            send: { _, _, _ in
                if await events.probe() == 1 { throw URLError(.networkConnectionLost) }
                return "ingested"
            }, notify: {})

        let failed = await worker.drain(endpoint: endpoint)
        #expect(failed.failed == 1)
        #expect(CompanionOutbox.waiting(in: directory).count == 1)
        let retried = await worker.drain(endpoint: endpoint)
        #expect(retried.sent == 1)
        #expect(CompanionOutbox.waiting(in: directory).isEmpty)
    }

    @Test func concurrentDeliveryRequestsSendARecordingOnce() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("recording".utf8).write(to: directory.appendingPathComponent("memo.wav"))
        let gate = DeliveryGate()
        let worker = CompanionOutboxDelivery(
            directory: directory,
            send: { _, _, _ in
                await gate.send()
                return "ingested"
            }, notify: {})
        await worker.enqueue(endpoint: endpoint)
        await gate.waitUntilStarted()
        await worker.enqueue(endpoint: endpoint)
        async let result = worker.drain(endpoint: endpoint)
        await gate.release()
        _ = await result

        #expect(await gate.count == 1)
        #expect(CompanionOutbox.waiting(in: directory).isEmpty)
    }

    @Test func eachDaemonPassHasABoundedBatch() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<(CompanionOutboxDelivery.batchSize + 2) {
            try Data("recording".utf8).write(to: directory.appendingPathComponent("\(index).wav"))
        }
        let worker = CompanionOutboxDelivery(
            directory: directory, send: { _, _, _ in "ingested" }, notify: {})

        let result = await worker.drain(endpoint: endpoint)

        #expect(result.sent == CompanionOutboxDelivery.batchSize)
        #expect(CompanionOutbox.waiting(in: directory).count == 2)
    }

    @Test func unacknowledgedAudioRemainsQueued() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("recording".utf8).write(to: directory.appendingPathComponent("memo.wav"))

        let result = await CompanionOutbox.drain(in: directory) { _, _ in "queued" }

        #expect(result.failed == 1)
        #expect(CompanionOutbox.waiting(in: directory).count == 1)
    }

    @Test func sameNamedRecordingsArePreservedSeparately() throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("memo.wav")
        let queue = directory.appendingPathComponent("queue")
        try Data("first".utf8).write(to: source)
        let first = try #require(CompanionOutbox.keep(source, in: queue))
        try Data("second".utf8).write(to: source)
        let second = try #require(CompanionOutbox.keep(source, in: queue))

        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try Data(contentsOf: second) == Data("second".utf8))
    }

    private func sandbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "companion-background-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor DeliveryEvents {
    private(set) var values: [String] = []
    private var probes = 0

    func append(_ value: String) { values.append(value) }

    func probe() -> Int {
        values.append("probe")
        probes += 1
        return probes
    }
}

private actor DeliveryGate {
    private(set) var count = 0
    private var waiting: CheckedContinuation<Void, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []

    func send() async {
        count += 1
        for waiter in started { waiter.resume() }
        started.removeAll()
        await withCheckedContinuation { waiting = $0 }
    }

    func waitUntilStarted() async {
        guard count == 0 else { return }
        await withCheckedContinuation { started.append($0) }
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }
}
