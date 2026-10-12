import AppKit
import Foundation
import Observation
import UserNotifications
import WorkerFixtureSupport

@MainActor
@Observable
final class VideoExporter {
    enum Phase: Equatable {
        case exporting
        case finished
        case failed(String)
    }

    struct Job: Identifiable {
        let id: UUID
        let destination: URL
        let startedAt: Date
        var progress = 0.0
        var phase = Phase.exporting
        var report: VideoDeliveryReport?
        var audioReport: VideoAudioDeliveryReport?

        init(id: UUID = UUID(), destination: URL, startedAt: Date = Date()) {
            self.id = id; self.destination = destination; self.startedAt = startedAt
        }

        var secondsRemaining: Double? {
            let elapsed = Date().timeIntervalSince(startedAt)
            guard phase == .exporting, progress > 0.02, elapsed > 2 else { return nil }
            return elapsed * (1 - progress) / progress
        }
    }

    typealias Work = (@escaping @Sendable (Double) -> Void) async throws -> Void

    static let shared = VideoExporter(onComplete: VideoExportBackground.complete)

    private(set) var job: Job?
    private var task: Task<Void, Never>?
    private let owned = StudioTaskOwner()
    private var suspended = false
    private var remoteToken: UUID?
    var remoteCancel: ((UUID) -> Void)?
    var remoteClear: ((UUID) -> Void)?
    func beginRemote(_ token: UUID) { remoteToken = token }
    private let onComplete: (Job?) async -> Void

    init(onComplete: @escaping (Job?) async -> Void = { _ in }) {
        self.onComplete = onComplete
    }

    var isExporting: Bool { job?.phase == .exporting }

    @discardableResult
    func start(to destination: URL, work: @escaping Work) -> Bool {
        guard !suspended, !isExporting else { return false }
        task?.cancel(); remoteToken = nil
        let started = Job(destination: destination)
        job = started
        let updates = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        task = owned.enqueue(
            { [weak self] in
                guard let self else { updates.continuation.finish(); return }
                async let progressUpdates: Void = Self.consumeProgress(
                    updates.stream, exporter: self, id: started.id)
                let outcome: Phase?
                do {
                    try Task.checkCancellation()
                    try await work { updates.continuation.yield($0) }
                    try Task.checkCancellation()
                    outcome = .finished
                } catch is CancellationError {
                    outcome = nil
                } catch {
                    outcome = Task.isCancelled ? nil : .failed(error.localizedDescription)
                }
                updates.continuation.finish()
                await progressUpdates
                await finish(started.id, outcome)
            }, runsWhenCancelled: true)
        return task != nil
    }

    @discardableResult
    func startNativeExport(
        admission: WorkerFixtureEngineAdmission,
        work:
            @escaping (
                WorkerFixtureNativeExportLease, WorkerFixtureNamespaceAction, URL,
                @escaping @Sendable (Double) -> Void
            ) async throws -> Void
    ) throws -> Bool {
        guard !suspended, !isExporting else { return false }
        try admission.requireCurrent()
        guard admission.descriptor.owner == "studio", admission.descriptor.role == "app",
            let publication = admission.descriptor.outputs.first(where: {
                $0.name == "exported-video"
            })
        else { throw WorkerFixtureError.invalid }
        guard
            let staging = admission.descriptor.outputs.first(where: {
                $0.name == "export-staging"
            })
        else { throw WorkerFixtureError.invalid }
        let destination = URL(fileURLWithPath: publication.path)
        let stage = URL(fileURLWithPath: staging.path)
        let lease = try admission.nativeExportLease(
            stageNamed: "export-staging", publicationNamed: "exported-video",
            inputsNamed: ["studio-project", "studio-source-video"])
        return start(to: destination) { progress in
            try await lease.withAction { action in
                try await work(lease, action, stage, progress)
                try Task.checkCancellation()
                guard try lease.publish(action) == destination else {
                    throw WorkerFixtureError.invalid
                }
            }
        }
    }

    private static func consumeProgress(
        _ updates: AsyncStream<Double>, exporter: VideoExporter, id: UUID
    ) async {
        for await value in updates { exporter.report(value, for: id) }
    }

    func suspendCommands() {
        suspended = true
        owned.shutdown()
        task?.cancel()
    }

    func suspendCommandsAndWait() async {
        suspendCommands()
        await owned.shutdownAndWait()
    }

    func waitForPendingWork() async { await owned.waitForPendingWork() }

    func pendingWorkCancellation() -> @Sendable () -> Void {
        let pending = task
        return { pending?.cancel() }
    }

    @discardableResult
    func detach() -> UUID? {
        let token = remoteToken
        task?.cancel()
        remoteToken = nil
        return token
    }

    func cancel() {
        if let task { task.cancel() } else if let remoteToken { remoteCancel?(remoteToken) }
    }

    func clear() {
        guard !isExporting else { return }
        job = nil
        if let remoteToken { remoteClear?(remoteToken) }; remoteToken = nil
    }

    func setReport(_ report: VideoDeliveryReport, for destination: URL) {
        guard job?.destination == destination, isExporting else { return }
        job?.report = report
    }

    func setAudioReport(_ report: VideoAudioDeliveryReport, for destination: URL) {
        guard job?.destination == destination, isExporting else { return }
        job?.audioReport = report
    }

    private func report(_ progress: Double, for id: UUID) {
        guard var current = job, current.id == id, current.phase == .exporting else { return }
        current.progress = min(1, max(current.progress, progress))
        job = current
    }

    private func finish(_ id: UUID, _ outcome: Phase?) async {
        guard job?.id == id else { return }
        task = nil
        if let outcome {
            job?.phase = outcome
            if outcome == .finished { job?.progress = 1 }
        } else {
            job = nil
        }
        await onComplete(job)
    }
}

@MainActor
enum VideoExportBackground {
    private static var quitsWhenDone = false

    static func keepsAppOpenAfterLastWindowClosed() -> Bool {
        guard VideoExporter.shared.isExporting else { return false }
        quitsWhenDone = true
        return true
    }

    static func defersQuit(_ application: NSApplication) -> Bool {
        guard VideoExporter.shared.isExporting else { return false }
        quitsWhenDone = true
        application.hide(nil)
        return true
    }

    static func userReturned() {
        quitsWhenDone = false
    }

    static func complete(_ job: VideoExporter.Job?) async {
        if let job, quitsWhenDone || !NSApp.isActive { await notify(job) }
        guard quitsWhenDone else { return }
        quitsWhenDone = false
        let windowOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if NSApp.isHidden || !windowOpen { NSApp.terminate(nil) }
    }

    private static func notify(_ job: VideoExporter.Job) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = job.phase == .finished ? "Export finished" : "Export failed"
        if case .failed(let message) = job.phase {
            content.body = "\(job.destination.lastPathComponent): \(message)"
        } else {
            content.body = job.destination.lastPathComponent
        }
        try? await center.add(
            UNNotificationRequest(
                identifier: "video-export-\(job.id)", content: content, trigger: nil))
    }
}

extension VideoExporter {
    func applyRemote(_ state: StudioUIVideoExport?) {
        guard let state else {
            if task == nil, remoteToken != nil { job = nil; remoteToken = nil }
            return
        }
        if task != nil, let remoteToken, remoteToken != state.token { return }
        if state.phase == "cancelled" { if task == nil { job = nil }; return }
        if task == nil, job?.id != state.token {
            job = Job(id: state.token, destination: state.destination, startedAt: state.startedAt)
        }
        remoteToken = state.token
        job?.progress = state.progress
        job?.report = state.videoReport; job?.audioReport = state.audioReport
        switch state.phase {
        case "running": job?.phase = .exporting
        case "completed": job?.phase = .finished
        case "failed": job?.phase = .failed(state.failure ?? "Export failed")
        default: break
        }
    }
}
