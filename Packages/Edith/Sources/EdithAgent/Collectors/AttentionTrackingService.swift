import AppKit
import ApplicationServices
import CoreGraphics
import EdithKit
import Foundation

@MainActor
final class AttentionTrackingService {
    private let repository: AttentionRepository
    private var settings: AttentionSettings
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var previous: AttentionHeartbeatSample?
    private let capture: @MainActor (Date, AttentionSettings, Bool) -> AttentionHeartbeatSample?
    private var locked = false
    private let writer: AttentionHeartbeatWriter
    nonisolated(unsafe) private var shutdownTask: Task<Void, Never>?

    init(
        repository: AttentionRepository = AttentionRepository(),
        writer: AttentionHeartbeatWriter? = nil, settings initialSettings: AttentionSettings? = nil,
        observe: Bool = true, now: Date = Date(),
        capture: @escaping @MainActor (Date, AttentionSettings, Bool) -> AttentionHeartbeatSample? =
            AttentionTrackingService.capture
    ) {
        self.writer =
            writer
            ?? AttentionHeartbeatWriter(
                spool: AttentionDeliverySpool(
                    file: repository.directory.appendingPathComponent("delivery-spool.json")))
        self.capture = capture
        self.repository = repository
        settings = initialSettings ?? repository.loadSettings()
        previous = capture(now, settings, locked)
        if observe {
            installObservers()
            startTimer()
        }
    }

    deinit { shutdownTask?.cancel() }

    @discardableResult
    func shutdown() -> Task<Void, Never> {
        if let shutdownTask { return shutdownTask }
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        writeHeartbeat()
        let writer = writer
        let task = Task { await writer.stop() }
        shutdownTask = task
        return task
    }

    func sync(_ nextSettings: AttentionSettings) {
        writeHeartbeat()
        settings = nextSettings
        previous = capture(Date(), settings, locked)
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeHeartbeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
        ]
        for name in names {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.handle(note) }
                })
        }
    }

    private func handle(_ notification: Notification) {
        writeHeartbeat()
        switch notification.name {
        case NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willSleepNotification:
            locked = true
        case NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.didWakeNotification:
            locked = false
        default: break
        }
        previous = capture(Date(), settings, locked)
    }

    func writeHeartbeat(now: Date = Date()) {
        let current = capture(now, settings, locked)
        defer { previous = current }
        guard var sample = previous else { return }
        let duration = now.timeIntervalSince(sample.event.startedAt)
        guard duration > 0, duration <= 30 else { return }
        sample.event.duration = duration
        writer.submit(sample)
    }

    private static func capture(
        now: Date, settings: AttentionSettings, locked: Bool
    ) -> AttentionHeartbeatSample? {
        guard settings.isEnabled, settings.trackingEnabled,
            let app = NSWorkspace.shared.frontmostApplication
        else { return nil }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        let presence: AttentionPresence =
            locked ? .locked : idleSeconds >= settings.idleThreshold ? .idle : .active
        return AttentionHeartbeatSample(
            event: AttentionEvent(
                startedAt: now, duration: 0, source: .application,
                presence: presence, appName: app.localizedName, bundleID: app.bundleIdentifier),
            processID: app.processIdentifier, captureWindowTitle: settings.windowTitlesEnabled)
    }
}

@MainActor
final class AttentionTrackingRuntime {
    private let repository: AttentionRepository
    private let deliver: AttentionHeartbeatWriter.Deliver
    private var collector: AttentionTrackingService?
    private var stopped = false

    nonisolated init(
        repository: AttentionRepository, deliver: @escaping AttentionHeartbeatWriter.Deliver
    ) {
        self.repository = repository
        self.deliver = deliver
    }

    func sync(_ settings: AttentionSettings) {
        guard !stopped else { return }
        if collector == nil {
            let writer = AttentionHeartbeatWriter(
                spool: AttentionDeliverySpool(
                    file: repository.directory.appendingPathComponent("delivery-spool.json")),
                deliver: deliver)
            collector = AttentionTrackingService(
                repository: repository, writer: writer, settings: settings)
        } else {
            collector?.sync(settings)
        }
    }

    func stop() async {
        stopped = true
        await collector?.shutdown().value
        collector = nil
    }
}
