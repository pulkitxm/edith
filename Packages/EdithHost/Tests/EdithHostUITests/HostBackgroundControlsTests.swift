import AppKit
import EdithExtensionUI
import EdithHostCore
import Foundation
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostBackgroundControlsTests {
    @Test func scalarProjectionPreservesActualOwnerCadencesStatusDatesAndEvents() async throws {
        let projection = try fixture()
        let model = HostBackgroundModel(
            environment: .init(
                identity: { "core:41|herdr:2:77" }, read: { projection }, control: { _, _ in }))
        await model.refresh()
        let job = try #require(model.jobs.first)
        #expect(job.id == "sessions.discover")
        #expect(job.interval == 120)
        #expect(job.lastRun == Date(timeIntervalSince1970: 1_000))
        #expect(job.lastDuration == 3)
        #expect(job.runCount == 6)
        #expect(job.lastError == "Synthetic permission unavailable")
        #expect(model.lastStatus(for: job) == job.lastError)
        #expect(
            model.events.first?.taskID == UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        #expect(model.current)
    }

    @Test func olderAndCancelledReadsCannotReplaceTheLatestProjection() async throws {
        let gate = Gate()
        let initial = try fixture()
        let latest = HostBackgroundProjection(
            jobs: [], events: initial.events, unavailable: "Synthetic owner off")
        let model = HostBackgroundModel(
            environment: .init(
                identity: { "core:41" }, read: { await gate.read() }, control: { _, _ in }))
        let first = Task { await model.refresh() }
        await gate.started(1)
        let second = Task { await model.refresh() }
        await gate.started(2)
        gate.finish(1, latest)
        await second.value
        gate.finish(0, initial)
        await first.value
        #expect(model.jobs.isEmpty)
        #expect(model.unavailable == latest.unavailable)
        let third = Task { await model.refresh() }
        await gate.started(3)
        third.cancel()
        gate.finish(2, initial)
        await third.value
        #expect(model.jobs.isEmpty)
        #expect(!model.load.isRunning)
        let fourth = Task { await model.refresh() }
        await gate.started(4)
        model.cancel()
        gate.finish(3, initial)
        await fourth.value
        #expect(model.jobs.isEmpty)
    }

    @Test(arguments: [
        "core:42|herdr:2:77", "core:41|herdr:3:77", "core:41|herdr:2:78", "core:41", "",
    ])
    func exactCoreOwnerVersionPIDAndDisableGatesRejectLateProjection(replacement: String)
        async throws
    {
        let gate = Gate()
        var identity: String? = "core:41|herdr:2:77"
        let model = HostBackgroundModel(
            environment: .init(
                identity: { identity }, read: { await gate.read() },
                control: { _, _ in Issue.record("Stale control reached owner") }))
        let flight = Task { await model.refresh() }
        await gate.started(1)
        identity = replacement.isEmpty ? nil : replacement
        gate.finish(0, try fixture())
        await flight.value
        #expect(model.jobs.isEmpty)
        #expect(!model.current)
        #expect(!model.load.isRunning)
        await model.control(try fixture().jobs[0])
    }

    @Test func runAndCancelUseExactAdvertisedJobAndNeverPublishCancelledAction() async throws {
        var commands: [(String, Bool)] = []
        var projection = try fixture()
        let model = HostBackgroundModel(
            environment: .init(
                identity: { "core:41" }, read: { projection },
                control: { id, cancel in commands.append((id, cancel)) }))
        await model.refresh()
        await model.control(model.jobs[0])
        #expect(commands.count == 1)
        #expect(commands[0].0 == "sessions.discover" && !commands[0].1)
        projection = try fixture(phase: "running")
        await model.refresh()
        await model.control(model.jobs[0])
        #expect(commands.count == 2)
        #expect(commands[1].1)
        await model.control(try fixture(id: "sessions.foreign").jobs[0])
        #expect(commands.count == 2)
        let flight = Task { await model.control(model.jobs[0]) }
        flight.cancel()
        await flight.value
        #expect(commands.count == 2)
        #expect(model.action == nil)
    }

    @Test func sectionsRenderWithoutAnApplicationWindowAtCompactRegularZoomAndBothSchemes()
        async throws
    {
        let projection = try fixture()
        let model = HostBackgroundModel(
            environment: .init(identity: { "core:41" }, read: { projection }, control: { _, _ in }))
        await model.refresh()
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for width in [520.0, 1100.0] {
            for zoom in [1.0, 1.4] {
                for scheme in [ColorScheme.light, .dark] {
                    UIScale.apply(zoom)
                    let view = NSHostingView(
                        rootView: VStack {
                            Form { HostBackgroundJobsSection(model: model) }.edithForm()
                            HostBackgroundEventTimeline(model: model)
                        }.environment(\.compactLayout, width == 520)
                            .environment(\.colorScheme, scheme)
                            .environment(\.automaticViewActionsEnabled, false)
                            .transaction { $0.animation = nil })
                    view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                    view.layoutSubtreeIfNeeded()
                    #expect(view.window == nil)
                    #expect(view.fittingSize.height > 0)
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                }
            }
        }
    }

    @Test func originalTimelineFiltersPaginatesPausesAndCopiesActualEvents() throws {
        let sample = try fixture().events[0]
        let timeline = HostBackgroundTimelineModel()
        let values = (0..<130).map { index in
            HostBackgroundEvent(
                id: UUID(), date: sample.date.addingTimeInterval(Double(index)),
                level: index.isMultiple(of: 2) ? "info" : "error", category: sample.category,
                name: sample.name, message: "Synthetic record \(index)", duration: nil,
                taskID: sample.taskID)
        }
        timeline.receive(values)
        #expect(timeline.visibleEvents.count == 50)
        timeline.loadMore()
        #expect(timeline.visibleEvents.count == 100)
        #expect(timeline.hasMore)
        timeline.failuresOnly = true
        #expect(timeline.matches.count == 65 && timeline.visibleEvents.count == 50)
        timeline.search = " record 129 "
        #expect(timeline.matches.count == 1)
        #expect(timeline.text.contains("[error] jobs.sessions.discover"))
        #expect(timeline.text.contains(sample.taskID!.uuidString))
        timeline.paused = true
        timeline.receive([])
        #expect(timeline.matches.count == 1)
        timeline.paused = false
        timeline.receive([])
        #expect(timeline.visibleEvents.isEmpty)
    }

    @Test func ownerProjectionValidationRejectsConflictsAndMalformedCadence() throws {
        let sample = try fixture()
        try HostBackgroundSource.validate(jobs: sample.jobs, events: sample.events)
        #expect(throws: (any Error).self) {
            try HostBackgroundSource.validate(
                jobs: sample.jobs + sample.jobs, events: sample.events)
        }
        #expect(throws: (any Error).self) {
            try HostBackgroundSource.validate(
                jobs: sample.jobs, events: sample.events + sample.events)
        }
        let job = try #require(sample.jobs.first)
        let invalid = HostBackgroundJob(
            descriptor: .init(
                id: job.id, title: "Synthetic",
                trigger: "timer", topic: nil, cadence: .init(ambient: -.infinity, live: nil),
                power: "any", abilityID: nil), phase: "idle", subscribers: 0, lastRun: nil,
            lastDuration: nil, lastError: nil, runCount: 0)
        #expect(throws: (any Error).self) {
            try HostBackgroundSource.validate(jobs: [invalid], events: [])
        }
    }

    @Test func actualProcessPinRejectsChangedVersionPIDDisabledAndPendingOwners() throws {
        let value: [String: Any] = [
            "id": "herdr", "installed": true, "compatible": true,
            "enabled": true, "running": true, "version": "2", "disablePending": false,
            "removalPending": false, "processIdentifier": getpid(),
        ]
        func state(_ fields: [String: Any]) throws -> HostCLIProviderState {
            try JSONDecoder().decode(
                HostCLIProviderState.self,
                from: JSONSerialization.data(withJSONObject: fields))
        }
        let expected = try state(value)
        let pin = try HostBackgroundOwnerPin(state: expected)
        #expect(pin.process.pid == getpid())
        #expect(pin.accepts([expected]))
        #expect(!pin.accepts([]))
        for (field, replacement) in [
            ("version", "3" as Any), ("processIdentifier", getpid() + 1),
            ("enabled", false), ("compatible", false), ("running", false),
            ("disablePending", true), ("removalPending", true),
        ] {
            var changed = value
            changed[field] = replacement
            let stale = try state(changed)
            #expect(!pin.accepts([stale]))
            if field != "version" && field != "processIdentifier" {
                #expect(throws: (any Error).self) { try HostBackgroundOwnerPin(state: stale) }
            }
        }
    }

    @Test func cancelledAndRetiredActionsCannotPublishLateFailures() async throws {
        let projection = try fixture()
        var continuation: CheckedContinuation<Void, any Error>?
        var signal: CheckedContinuation<Void, Never>?
        var identity = "core:41"
        let model = HostBackgroundModel(
            environment: .init(
                identity: { identity }, read: { projection },
                control: { _, _ in
                    try await withCheckedThrowingContinuation { pending in
                        continuation = pending
                        signal?.resume()
                        signal = nil
                    }
                }))
        await model.refresh()
        let flight = Task { await model.control(model.jobs[0]) }
        if continuation == nil { await withCheckedContinuation { signal = $0 } }
        #expect(model.action == "sessions.discover")
        identity = "core:42"
        model.cancel()
        flight.cancel()
        continuation?.resume(throwing: CocoaError(.fileReadUnknown))
        await flight.value
        #expect(model.failure == nil)
        #expect(model.action == nil)
        #expect(!model.current)
    }

    private func fixture(id: String = "sessions.discover", phase: String = "failed") throws
        -> HostBackgroundProjection
    {
        let decoder = JSONDecoder()
        let jobs = try decoder.decode(
            [HostBackgroundJob].self,
            from: Data(
                """
                [{"descriptor":{"id":"\(id)","title":"Synthetic discovery","trigger":"timer","topic":"sessions","cadence":{"ambient":120,"live":5},"power":"pauseOnBattery","abilityID":"herdr"},"phase":"\(phase)","subscribers":0,"lastRun":-978306200,"lastDuration":3,"lastError":"Synthetic permission unavailable","runCount":6}]
                """.utf8))
        let events = try decoder.decode(
            [HostBackgroundEvent].self,
            from: Data(
                """
                [{"id":"00000000-0000-0000-0000-000000000001","date":-978306197,"level":"warning","category":"jobs","name":"sessions.discover","message":"Synthetic recurring job paused","duration":3,"taskID":"00000000-0000-0000-0000-000000000003"}]
                """.utf8))
        return .init(jobs: jobs, events: events, unavailable: nil)
    }

    @MainActor private final class Gate {
        private var reads: [CheckedContinuation<HostBackgroundProjection, Never>] = []
        private var signals: [(Int, CheckedContinuation<Void, Never>)] = []
        func read() async -> HostBackgroundProjection {
            await withCheckedContinuation { continuation in
                reads.append(continuation)
                let ready = signals.filter { $0.0 <= reads.count }
                signals.removeAll { $0.0 <= reads.count }
                ready.forEach { $0.1.resume() }
            }
        }
        func started(_ count: Int) async {
            if reads.count >= count { return }
            await withCheckedContinuation { signals.append((count, $0)) }
        }
        func finish(_ index: Int, _ projection: HostBackgroundProjection) {
            reads[index].resume(returning: projection)
        }
    }
}
