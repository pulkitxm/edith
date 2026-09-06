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
    private var lastHeartbeatAt = Date()
    private var locked = false
    private let writer: AttentionHeartbeatWriter
    nonisolated(unsafe) private var shutdownTask: Task<Void, Never>?

    init(
        repository: AttentionRepository = AttentionRepository(),
        writer: AttentionHeartbeatWriter? = nil
    ) {
        self.writer =
            writer
            ?? AttentionHeartbeatWriter(
                spool: AttentionDeliverySpool(
                    file: repository.directory.appendingPathComponent("delivery-spool.json")))
        self.repository = repository
        settings = repository.loadSettings()
        installObservers()
        startTimer()
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

    }

    private func startTimer() {
        lastHeartbeatAt = Date()
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
        lastHeartbeatAt = Date()
    }

    private func writeHeartbeat(now: Date = Date()) {
        let duration = min(30, max(0, now.timeIntervalSince(lastHeartbeatAt)))
        guard settings.isEnabled, settings.trackingEnabled, duration > 0.2,
            let app = NSWorkspace.shared.frontmostApplication
        else {
            lastHeartbeatAt = now
            return
        }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        let presence: AttentionPresence =
            locked ? .locked : idleSeconds >= settings.idleThreshold ? .idle : .active
        let event = AttentionEvent(
            startedAt: lastHeartbeatAt, duration: duration, source: .application,
            presence: presence, appName: app.localizedName, bundleID: app.bundleIdentifier)
        lastHeartbeatAt = now
        writer.submit(
            AttentionHeartbeatSample(
                event: event, processID: app.processIdentifier,
                captureWindowTitle: settings.windowTitlesEnabled))
    }
}
