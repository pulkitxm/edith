import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

private struct AttentionDaemonFixture {
    let root: URL
    let store: AgentStore
    let events: AttentionEventStore
    let repository: AttentionRepository
    let defaults: UserDefaults
    let suite: String
    let service: AttentionBackgroundService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttentionDaemon.\(UUID().uuidString)")
        store = try AgentStore(url: root.appendingPathComponent("store.sqlite"), build: "test")
        events = AttentionEventStore(store: store)
        repository = AttentionRepository(root: root)
        suite = "AttentionDaemon.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: AppStorageKeys.Tabs.attentionEnabled)
        service = AttentionBackgroundService(
            store: store, root: root, cloudDirectory: root.appendingPathComponent("cloud"),
            defaults: defaults, cloudAvailable: { true })
    }

    func close() async {
        await service.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func event(at date: Date, duration: TimeInterval = 5) -> AttentionEvent {
        AttentionEvent(
            startedAt: date, duration: duration, source: .application,
            appName: "Writing", bundleID: "app.writing")
    }
}

@Suite struct AttentionDaemonIntegrationTests {
    @Test func duplicateCategoryIdentifiersCannotCrashTheDaemonSummary() async throws {
        let fixture = try AttentionDaemonFixture()
        let now = Date()
        try await fixture.service.record(
            AttentionBatch(events: [fixture.event(at: now.addingTimeInterval(-30))]))
        let category = AttentionSettings.defaultCategories[0]
        let settings = AttentionSettings(categories: [category, category])
        let summary = try await fixture.service.summary(
            AttentionSummaryRequest(from: now.addingTimeInterval(-60), to: now, settings: settings))
        #expect(summary.hasStoredEvents)
        #expect(summary.events.count == 1)
        await fixture.close()
    }

    @Test func failedMetadataPublicationRollsBackImportedEvents() async throws {
        let fixture = try AttentionDaemonFixture()
        let event = fixture.event(at: Date().addingTimeInterval(-30))
        try fixture.repository.append(event)
        #expect(throws: CocoaError.self) {
            try fixture.events.restoreEvents(from: fixture.repository.eventsDirectory) {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        #expect(try !fixture.events.hasEvents())
        try fixture.events.restoreEvents(from: fixture.repository.eventsDirectory)
        #expect(try fixture.events.hasEvents())
        await fixture.close()
    }

    @Test func malformedRestoredSettingsLeaveEventsEmptyAndAllowRetry() async throws {
        let fixture = try AttentionDaemonFixture()
        let cloud = fixture.root.appendingPathComponent("cloud")
        try fixture.repository.append(fixture.event(at: Date().addingTimeInterval(-30)))
        try AttentionCloudBackup(
            localDirectory: fixture.repository.directory, cloudDirectory: cloud
        ).backup()
        try FileManager.default.removeItem(at: fixture.repository.eventsDirectory)
        try Data("invalid settings".utf8).write(to: cloud.appendingPathComponent("settings.json"))
        await #expect(throws: (any Error).self) { try await fixture.service.restore() }
        #expect(try !fixture.events.hasEvents())
        try AgentPayload.encode(AttentionSettings()).write(
            to: cloud.appendingPathComponent("settings.json"))
        try await fixture.service.restore()
        #expect(try fixture.events.hasEvents())
        await fixture.close()
    }

    @Test func shutdownRejectsNewWorkAndCannotRestartTheListener() async throws {
        let fixture = try AttentionDaemonFixture()
        await fixture.service.start()
        await fixture.service.stop()
        await fixture.service.start()
        await #expect(throws: CancellationError.self) { try await fixture.service.run() }
        await #expect(throws: CancellationError.self) { try await fixture.service.backup() }
        await #expect(throws: CancellationError.self) {
            try await fixture.service.summary(
                AttentionSummaryRequest(from: Date().addingTimeInterval(-60), to: Date()))
        }
        await #expect(throws: CancellationError.self) { try await fixture.service.hasEvents() }
        await fixture.close()
    }

    @Test func backgroundIngestionHasAnAmbientBackupCadence() throws {
        let descriptor = try #require(
            AgentJobPlan.descriptors.first { $0.id == "attention.ingest" })
        #expect(descriptor.trigger == .timer)
        #expect(descriptor.cadence == .every(ambient: 900, live: 900))
    }

    @Test func continuousApplicationSamplesUseOneRowPerDay() async throws {
        let fixture = try AttentionDaemonFixture()
        defer { Task { await fixture.close() } }
        let start = AttentionPaths.utcCalendar.startOfDay(for: Date()).addingTimeInterval(3600)
        for index in 0..<300 {
            try fixture.events.record(
                AttentionBatch(events: [
                    fixture.event(at: start.addingTimeInterval(Double(index) * 5))
                ]),
                now: start.addingTimeInterval(2000))
        }
        let rows = try fixture.events.events(from: start, to: start.addingTimeInterval(2000))
        #expect(rows.count == 1)
        #expect(rows.first?.duration == 1500)
        #expect(try fixture.events.hasEvents())
    }

    @Test func mergingStopsAtTheUTCDayBoundary() async throws {
        let fixture = try AttentionDaemonFixture()
        defer { Task { await fixture.close() } }
        let midnight = AttentionPaths.utcCalendar.startOfDay(for: Date())
        try fixture.events.record(
            AttentionBatch(events: [
                fixture.event(at: midnight.addingTimeInterval(-5)), fixture.event(at: midnight),
            ]),
            now: midnight.addingTimeInterval(10))
        #expect(
            try fixture.events.events(
                from: midnight.addingTimeInterval(-10), to: midnight.addingTimeInterval(10)
            ).count == 2)
    }

    @Test func fallbackEventsAreImportedAgainAfterAnEarlierSuccessfulDrain() async throws {
        let fixture = try AttentionDaemonFixture()
        defer { Task { await fixture.close() } }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        try fixture.repository.append(fixture.event(at: now.addingTimeInterval(-100)))
        #expect(try await fixture.service.importSpool().events == 1)
        #expect(!fixture.repository.hasEvents())
        try fixture.repository.append(fixture.event(at: now.addingTimeInterval(-20)))
        let range = try await fixture.service.range(
            AttentionRangeRequest(from: now.addingTimeInterval(-200), to: now))
        #expect(range.events.count == 2)
        #expect(!fixture.repository.hasEvents())
        #expect(try await fixture.service.hasEvents())
    }

    @Test func failedDatabaseImportKeepsTheDurableFallbackFile() async throws {
        let fixture = try AttentionDaemonFixture()
        defer { Task { await fixture.close() } }
        let event = fixture.event(at: Date())
        try fixture.repository.append(event)
        try fixture.store.close()
        #expect(throws: (any Error).self) {
            try fixture.events.importLegacyFiles(directory: fixture.repository.eventsDirectory)
        }
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.repository.eventFile(for: event.startedAt).path))
    }

    @Test func theDaemonAloneServesAuthenticatedBrowserHeartbeats() async throws {
        let fixture = try AttentionDaemonFixture()
        defer { Task { await fixture.close() } }
        try fixture.repository.saveSettings(
            AttentionSettings(
                isEnabled: true, browserTrackingEnabled: true, serverPort: 0,
                serverToken: "fixture-token"))
        var port: UInt16?
        for _ in 0..<100 {
            let data = try #require(try await fixture.service.run())
            let status = try AgentPayload.decode(AttentionRuntimeSnapshot.self, from: data)
            if status.browserListening {
                port = status.port
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let boundPort = try #require(port)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(boundPort)/v1/heartbeat")!)
        request.httpMethod = "POST"
        request.httpBody = try AgentPayload.encode(
            AttentionBrowserHeartbeat(
                timestamp: now, duration: 15, presence: .active, appName: "Browser",
                url: "https://example.com/private?token=hidden"))
        request.setValue("wrong", forHTTPHeaderField: "X-Edith-Token")
        let (_, unauthorized) = try await URLSession.shared.data(for: request)
        #expect((unauthorized as? HTTPURLResponse)?.statusCode == 401)
        request.setValue("fixture-token", forHTTPHeaderField: "X-Edith-Token")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 202)
        let events = try fixture.events.events(from: now, to: now.addingTimeInterval(20))
        #expect(events.count == 1)
        #expect(events.first?.domain == "example.com")
        #expect(events.first?.url == nil)
        fixture.defaults.set(false, forKey: AppStorageKeys.Tabs.attentionEnabled)
        let stopped = try #require(try await fixture.service.run())
        #expect(try AgentPayload.decode(AttentionRuntimeSnapshot.self, from: stopped).port == nil)
    }

    @Test func daemonSummaryReportsStoredEventsAfterSpoolFilesAreGone() async throws {
        let fixture = try AttentionDaemonFixture()
        defer { Task { await fixture.close() } }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        try await fixture.service.record(
            AttentionBatch(events: [fixture.event(at: now.addingTimeInterval(-30), duration: 30)]))
        let snapshot = try await fixture.service.summary(
            AttentionSummaryRequest(from: now.addingTimeInterval(-60), to: now))
        #expect(snapshot.hasStoredEvents)
        #expect(snapshot.events.count == 1)
        #expect(snapshot.summary.activeDuration == 30)
        #expect(!fixture.repository.hasEvents())
    }

    @Test func cloudBackupRoundTripsSQLiteEventsThroughDaemonOperations() async throws {
        let fixture = try AttentionDaemonFixture()
        defer { Task { await fixture.close() } }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        try fixture.events.record(
            AttentionBatch(events: [fixture.event(at: now.addingTimeInterval(-30), duration: 30)]))
        let runtime = AgentRuntime(build: "test", store: fixture.store)
        await AttentionBackgroundOperations.register(on: runtime, service: fixture.service)
        _ = try await runtime.perform(operation: AttentionOperation.backup, payload: Data())
        let restoredRoot = fixture.root.appendingPathComponent("restored")
        let restoredStore = try AgentStore(
            url: restoredRoot.appendingPathComponent("store.sqlite"), build: "test")
        let restored = AttentionBackgroundService(
            store: restoredStore, root: restoredRoot,
            cloudDirectory: fixture.root.appendingPathComponent("cloud"),
            defaults: fixture.defaults, cloudAvailable: { true })
        try await restored.restore()
        let events = try await restored.range(
            AttentionRangeRequest(from: now.addingTimeInterval(-60), to: now))
        #expect(events.events.count == 1)
        #expect(events.events.first?.appName == "Writing")
        await #expect(throws: AttentionCloudBackupError.localStoreNotEmpty) {
            try await restored.restore()
        }
        await restored.stop()
    }

    @Test func restoreChecksEmptinessInsideTheDatabaseTransaction() async throws {
        let fixture = try AttentionDaemonFixture()
        defer { Task { await fixture.close() } }
        let event = fixture.event(at: Date().addingTimeInterval(-30))
        try fixture.repository.append(event)
        try fixture.events.record(AttentionBatch(events: [event]))
        #expect(throws: AttentionCloudBackupError.localStoreNotEmpty) {
            try fixture.events.restoreEvents(from: fixture.repository.eventsDirectory)
        }
        #expect(fixture.repository.hasEvents())
        #expect(try fixture.events.hasEvents())
    }

    @Test func corruptBackupRollsBackTheWholeRestore() async throws {
        let fixture = try AttentionDaemonFixture()
        defer { Task { await fixture.close() } }
        let event = fixture.event(at: Date().addingTimeInterval(-30))
        try fixture.repository.append(event)
        let invalid = fixture.repository.eventsDirectory.appendingPathComponent("zz-invalid.jsonl")
        try Data("corrupt\n".utf8).write(to: invalid)
        #expect(throws: (any Error).self) {
            try fixture.events.restoreEvents(from: fixture.repository.eventsDirectory)
        }
        #expect(try !fixture.events.hasEvents())
        #expect(fixture.repository.hasEvents())
    }

    @Test func daemonSummaryPropagatesDatabaseFailure() async throws {
        let fixture = try AttentionDaemonFixture()
        defer { Task { await fixture.close() } }
        try fixture.store.close()
        await #expect(throws: (any Error).self) {
            try await fixture.service.summary(
                AttentionSummaryRequest(from: Date().addingTimeInterval(-60), to: Date()))
        }
    }

    @Test func replayedFallbackCannotShortenAnAlreadyMergedEvent() async throws {
        let fixture = try AttentionDaemonFixture()
        defer { Task { await fixture.close() } }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let event = fixture.event(at: now.addingTimeInterval(-30))
        try fixture.repository.append(event)
        try fixture.events.record(
            AttentionBatch(events: [
                event, fixture.event(at: now.addingTimeInterval(-25)),
            ]))
        try await fixture.service.importSpool()
        let rows = try fixture.events.events(from: now.addingTimeInterval(-60), to: now)
        #expect(rows.count == 1)
        #expect(rows.first?.duration == 10)
    }

    @Test func malformedFallbackIsPreservedWithoutBlockingLaterSamples() async throws {
        let fixture = try AttentionDaemonFixture()
        defer { Task { await fixture.close() } }
        let event = fixture.event(at: Date().addingTimeInterval(-30))
        try fixture.repository.append(event)
        let file = fixture.repository.eventFile(for: event.startedAt)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("invalid-record\n".utf8))
        try handle.close()
        #expect(try await fixture.service.importSpool().events == 1)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: fixture.repository.eventsDirectory.path)
        #expect(files.contains { $0.contains("unreadable") })
        try fixture.repository.append(fixture.event(at: Date().addingTimeInterval(-10)))
        #expect(try await fixture.service.importSpool().events == 1)
    }

    @Test func malformedContentLengthsCannotOverflowOrCreateInvalidRanges() {
        for value in ["-1", String(Int.max), "not-a-number", "1048576"] {
            let data = Data(
                "POST /v1/heartbeat HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n{}".utf8)
            #expect(AttentionHTTPRequest.parse(data) == nil)
        }
    }
}
