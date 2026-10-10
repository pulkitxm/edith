import AppKit
import EdithExtensionUI
@testable import EdithHostCore
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
                            .environment(\.windowVisible, false)
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

    @Test func actualCurrentCoreJournalDrivesRunCancelAndRetainedTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HostCoreAgentStore(directory: root)
        var execution: UUID?
        func projection() throws -> HostBackgroundProjection {
            let snapshot = HostCoreSnapshot(
                pid: getpid(), startedAt: Date(), collectedAt: Date(), residentBytes: 0,
                cpuSeconds: 0, storage: nil, tasks: [], cloudDirectory: root,
                cloudAvailable: false, agent: store.snapshot())
            return try HostBackgroundSource.decodeCore(JSONEncoder().encode(snapshot))
        }
        let agent = HostCoreAgentCLIFactory.make(
            local: .init(
                ownedJobs: { Set(store.snapshot().jobs.map(\.id)) },
                status: { throw HostCLIError.unavailable }, jobs: { store.snapshot().jobs },
                restart: { throw HostCLIError.unavailable }, logs: { _ in [] },
                events: { store.snapshot().events },
                run: { job in
                    let token = UUID()
                    try store.begin(job: job, execution: token)
                    execution = token
                },
                cancel: { _ in
                    try store.finish(
                        execution: try #require(execution), phase: .cancelled,
                        message: "Synthetic cancellation")
                    execution = nil
                }),
            invoke: { request in
                guard request.action == .ls else { throw HostCLIError.unavailable }
                return Data("[]".utf8)
            })
        let model = HostBackgroundModel(
            environment: .init(
                identity: { "synthetic-current-core" }, read: { try projection() },
                control: { job, cancel in
                    let reply = try await agent.execute([cancel ? "cancel" : "run", job, "--json"])
                    #expect(reply.exitCode == 0)
                    let result = try JSONDecoder().decode(
                        [String: String].self, from: Data(reply.stdout.utf8))
                    #expect(result[cancel ? "cancelled" : "queued"] == job)
                }))
        await model.refresh()
        let job = try #require(model.jobs.first { $0.id == "backup.sync" })
        #expect(job.interval == 86400)
        await model.control(job)
        let running = try #require(model.jobs.first { $0.id == job.id })
        #expect(running.phase == "running" && running.runCount == 1)
        #expect(running.lastRun != nil)
        await model.control(running)
        let cancelled = try #require(model.jobs.first { $0.id == job.id })
        #expect(cancelled.phase == "idle" && cancelled.lastDuration != nil)
        #expect(model.lastStatus(for: cancelled) == "Synthetic cancellation")
        #expect(
            model.events.first { $0.message == "Synthetic cancellation" }?.level == "warning")
        let restored = try HostCoreAgentStore(directory: root).snapshot()
        #expect(restored.jobs.first { $0.id == job.id }?.runCount == 1)
        #expect(restored.events.contains { $0.message == "Synthetic cancellation" })
    }

    @Test func originalNotificationFactoryPinsExactRouteAndRejectsLateReplacedOwner() async throws {
        let presenter = NotificationPresenter()
        var states = [try notificationState()]
        let model = HostBackgroundNotifications(presenter: presenter, states: { states })
        let first = Task { await model.refresh() }
        await presenter.started(1)
        let request = try #require(presenter.requests.first)
        #expect(request.extensionID == "herdr")
        #expect(request.location == "settings" && request.section == "backgroundAgent")
        states = [try notificationState(version: "3")]
        presenter.finish(0)
        await first.value
        #expect(model.controller == nil && model.failure == nil)
        #expect(presenter.ended.contains(request.presentationID))
        states = [try notificationState()]
        let second = Task { await model.refresh() }
        await presenter.started(2)
        let third = Task { await model.refresh() }
        await presenter.started(3)
        presenter.finish(2)
        await third.value
        let current = model.controller
        #expect(current != nil && current?.view.window == nil)
        #expect(model.current(version: "2", runtimeVersion: "2", pid: getpid(), active: true))
        #expect(!model.current(version: "3", runtimeVersion: "2", pid: getpid(), active: true))
        #expect(!model.current(version: "2", runtimeVersion: "3", pid: getpid(), active: true))
        #expect(!model.current(version: "2", runtimeVersion: "2", pid: getpid() + 1, active: true))
        #expect(!model.current(version: "2", runtimeVersion: "2", pid: getpid(), active: false))
        presenter.finish(1)
        await second.value
        #expect(model.controller === current)
        model.cancel()
        #expect(model.controller == nil)
        let fourth = Task { await model.refresh() }
        await presenter.started(4)
        fourth.cancel()
        presenter.finish(3)
        await fourth.value
        #expect(model.controller == nil && model.failure == nil)
    }

    @Test(arguments: ["compatible", "enabled", "running", "disablePending", "removalPending"])
    func inactiveOrIncompatibleNotificationOwnerNeverReachesFactory(field: String) async throws {
        let presenter = NotificationPresenter()
        let state = try notificationState(changed: field)
        let model = HostBackgroundNotifications(presenter: presenter, states: { [state] })
        await model.refresh()
        #expect(presenter.requests.isEmpty)
        #expect(model.controller == nil)
    }

    private func notificationState(version: String = "2", changed: String? = nil) throws
        -> HostCLIProviderState
    {
        var value: [String: Any] = [
            "id": "herdr", "installed": true, "compatible": true, "enabled": true,
            "running": true, "version": version, "disablePending": false,
            "removalPending": false, "processIdentifier": getpid(),
        ]
        if let changed { value[changed] = changed.hasSuffix("Pending") }
        return try JSONDecoder().decode(
            HostCLIProviderState.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @MainActor private final class NotificationPresenter: HostExtensionContentPresenting {
        var requests: [HostExtensionContentRequest] = []
        var ended: [UUID] = []
        var flights: [CheckedContinuation<NSViewController, Never>] = []
        var signals: [(Int, CheckedContinuation<Void, Never>)] = []

        func controller(for request: HostExtensionContentRequest) async throws -> NSViewController {
            requests.append(request)
            return await withCheckedContinuation { continuation in
                flights.append(continuation)
                let ready = signals.filter { $0.0 <= flights.count }
                signals.removeAll { $0.0 <= flights.count }
                ready.forEach { $0.1.resume() }
            }
        }

        func started(_ count: Int) async {
            if flights.count >= count { return }
            await withCheckedContinuation { signals.append((count, $0)) }
        }

        func finish(_ index: Int) {
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 120))
            flights[index].resume(returning: controller)
        }

        func endPresentation(id: UUID) { ended.append(id) }
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
