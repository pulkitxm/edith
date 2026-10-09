import CoreGraphics
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

    @Test func hardwareInputTypesIgnoreSessionNoiseAndHandleUnavailableReadings() {
        #expect(!AttentionSystemActivity.inputTypes.contains(CGEventType(rawValue: UInt32.max)!))
        #expect(AttentionSystemActivity.inputTypes.contains(.mouseMoved))
        #expect(AttentionSystemActivity.inputTypes.contains(.scrollWheel))
        #expect(AttentionSystemActivity.inputTypes.contains(.tabletPointer))
        let elapsed = AttentionSystemActivity.idleSeconds { type in
            type == .keyDown ? 600 : type == .scrollWheel ? 400 : .infinity
        }
        #expect(elapsed == 400)
        #expect(
            AttentionSystemActivity.presence(idleSeconds: elapsed, threshold: 300, locked: false)
                == .idle)
        #expect(
            AttentionSystemActivity.presence(idleSeconds: elapsed, threshold: 300, locked: true)
                == .locked)
        #expect(AttentionSystemActivity.idleSeconds { _ in .nan } == nil)
        #expect(AttentionSystemActivity.idleSeconds { _ in -1 } == nil)
        #expect(
            AttentionSystemActivity.presence(idleSeconds: nil, threshold: 300, locked: false)
                == .idle)
        for input in AttentionSystemActivity.inputTypes {
            let seconds = AttentionSystemActivity.idleSeconds { $0 == input ? 2 : 600 }
            #expect(
                AttentionSystemActivity.presence(
                    idleSeconds: seconds, threshold: 300, locked: false) == .active)
        }
    }

    @Test func idleThresholdAndResumeSplitTheHeartbeatAtTheLastHardwareInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = AttentionRecordedSamples()
        let writer = AttentionHeartbeatWriter(
            spool: AttentionDeliverySpool(file: root.appendingPathComponent("delivery.json")),
            prepare: { $0.event }, deliver: { await recorded.append($0.batch) })
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var seconds: TimeInterval = 298
        let collector = AttentionTrackingService(
            repository: AttentionRepository(root: root), writer: writer,
            settings: AttentionSettings(isEnabled: true, trackingEnabled: true),
            observe: false, now: now
        ) { date, settings, _ in
            AttentionHeartbeatSample(
                event: AttentionEvent(
                    startedAt: date, duration: 0, source: .application,
                    presence: AttentionSystemActivity.presence(
                        idleSeconds: seconds, threshold: settings.idleThreshold, locked: false),
                    appName: "Fixture editor"), processID: 0, captureWindowTitle: false,
                idleSeconds: seconds)
        }
        seconds = 303
        collector.writeHeartbeat(now: now.addingTimeInterval(5))
        seconds = 1
        collector.writeHeartbeat(now: now.addingTimeInterval(10))
        await writer.flush()
        let events = await recorded.events
        #expect(events.map(\.presence) == [.active, .idle, .idle, .active])
        #expect(events.map(\.duration) == [2, 3, 4, 1])
        #expect(events.map { $0.startedAt.timeIntervalSince(now) } == [0, 2, 5, 9])
        #expect(Set(events.map(\.id)).count == 4)
        await collector.shutdown().value
    }

    @Test func eightHoursWithoutInputOnlyCreditsTheInitialGracePeriod() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = AttentionRecordedSamples()
        let writer = AttentionHeartbeatWriter(
            spool: AttentionDeliverySpool(file: root.appendingPathComponent("delivery.json")),
            maximumPending: 1024, prepare: { $0.event },
            deliver: { await recorded.append($0.batch) })
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let collector = AttentionTrackingService(
            repository: AttentionRepository(root: root), writer: writer,
            settings: AttentionSettings(isEnabled: true, trackingEnabled: true),
            observe: false, now: now
        ) { date, settings, _ in
            let seconds = date.timeIntervalSince(now)
            return AttentionHeartbeatSample(
                event: AttentionEvent(
                    startedAt: date, duration: 0, source: .application,
                    presence: AttentionSystemActivity.presence(
                        idleSeconds: seconds, threshold: settings.idleThreshold, locked: false),
                    appName: "Fixture editor"), processID: 0, captureWindowTitle: false,
                idleSeconds: seconds)
        }
        for step in 1...960 {
            collector.writeHeartbeat(now: now.addingTimeInterval(Double(step) * 30))
        }
        await writer.flush()
        let events = await recorded.events
        let active = events.filter { $0.presence == .active }.reduce(0) { $0 + $1.duration }
        let idle = events.filter { $0.presence == .idle }.reduce(0) { $0 + $1.duration }
        #expect(active == 300)
        #expect(idle == 28_500)
        #expect(active + idle == 28_800)
        if ProcessInfo.processInfo.environment["EDITH_ATTENTION_IDLE_EVIDENCE"] == "1" {
            print("native collector fixture: unattended 8h, active 5m, idle 7h 55m")
        }
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

@Test func frontmostIdentityIsResolvedOncePerProcess() {
    FrontmostIdentityLookup.reset()
    var reads = 0
    for _ in 0..<20 {
        let identity = FrontmostIdentityLookup.identity(pid: 42) {
            reads += 1
            return (name: "Edith", bundleID: "com.example.edith")
        }
        #expect(identity.name == "Edith")
        #expect(identity.bundleID == "com.example.edith")
    }
    #expect(reads == 1)
    #expect(FrontmostIdentityLookup.lookups == 1)
    _ = FrontmostIdentityLookup.identity(pid: 43) {
        reads += 1
        return (name: "Other", bundleID: nil)
    }
    #expect(reads == 2)
    #expect(FrontmostIdentityLookup.lookups == 2)
}
