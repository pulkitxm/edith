import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

private actor AttentionRecordedSamples {
    var events: [AttentionEvent] = []
    func append(_ batch: AttentionBatch) { events += batch.events }
}

@MainActor @Suite struct AttentionTrackingTests {
    @Test func activationCreditsThePreviousAppAndDiscardsSleepGaps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AttentionRepository(root: root)
        let settings = AttentionSettings(isEnabled: true, trackingEnabled: true)
        let recorded = AttentionRecordedSamples()
        let writer = AttentionHeartbeatWriter(
            spool: AttentionDeliverySpool(file: root.appendingPathComponent("delivery.json")),
            prepare: { $0.event }, deliver: { await recorded.append($0.batch) })
        var app = "Editor"
        var presence = AttentionPresence.active
        let now = Date()
        let collector = AttentionTrackingService(
            repository: repository, writer: writer, settings: settings, observe: false, now: now
        ) { date, settings, _ in
            guard settings.isEnabled, settings.trackingEnabled else { return nil }
            return AttentionHeartbeatSample(
                event: AttentionEvent(
                    startedAt: date, duration: 0, source: .application,
                    presence: presence, appName: app), processID: 0, captureWindowTitle: false)
        }
        app = "Browser"
        collector.writeHeartbeat(now: now.addingTimeInterval(5))
        await writer.flush()
        var events = await recorded.events
        #expect(events.count == 1)
        #expect(events.first?.appName == "Editor")
        #expect(events.first?.duration == 5)
        presence = .idle
        collector.writeHeartbeat(now: now.addingTimeInterval(10))
        await writer.flush()
        events = await recorded.events
        #expect(events.last?.appName == "Browser")
        #expect(events.last?.presence == .active)
        collector.writeHeartbeat(now: now.addingTimeInterval(15))
        await writer.flush()
        #expect(await recorded.events.last?.presence == .idle)
        collector.writeHeartbeat(now: now.addingTimeInterval(3600))
        await writer.flush()
        #expect(await recorded.events.count == 3)
        await collector.shutdown().value
    }

    @Test func disabledCollectionNeverSubmitsAnInitialSample() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = AttentionRecordedSamples()
        let writer = AttentionHeartbeatWriter(
            spool: AttentionDeliverySpool(file: root.appendingPathComponent("delivery.json")),
            prepare: { $0.event }, deliver: { await recorded.append($0.batch) })
        let now = Date()
        let collector = AttentionTrackingService(
            repository: AttentionRepository(root: root), writer: writer,
            settings: AttentionSettings(isEnabled: false, trackingEnabled: true),
            observe: false, now: now)
        collector.writeHeartbeat(now: now.addingTimeInterval(5))
        await writer.flush()
        #expect(await recorded.events.isEmpty)
        await collector.shutdown().value
    }
}
