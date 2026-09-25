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
    private let observing: Bool
    private let media: AttentionMediaObserver?
    private var mediaSegments: [String: (id: String, startedAt: Date, lastSeen: Date)] = [:]
    private var lastHeartbeat: Date?
    nonisolated(unsafe) private var shutdownTask: Task<Void, Never>?

    init(
        repository: AttentionRepository = AttentionRepository(),
        writer: AttentionHeartbeatWriter? = nil, settings initialSettings: AttentionSettings? = nil,
        observe: Bool = true, now: Date = Date(),
        capture: @escaping @MainActor (Date, AttentionSettings, Bool) -> AttentionHeartbeatSample? =
            AttentionTrackingService.capture,
        media: AttentionMediaObserver? = nil
    ) {
        self.writer =
            writer
            ?? AttentionHeartbeatWriter(
                spool: AttentionDeliverySpool(
                    file: repository.directory.appendingPathComponent("delivery-spool.json")))
        self.capture = capture
        self.repository = repository
        settings = initialSettings ?? repository.loadSettings()
        observing = observe
        self.media = media ?? (observe ? AttentionMediaObserver() : nil)
        previous = capture(now, settings, locked)
        if observe {
            installObservers()
            syncTimer()
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
        media?.stop()
        let writer = writer
        let task = Task { await writer.stop() }
        shutdownTask = task
        return task
    }

    func sync(_ nextSettings: AttentionSettings) {
        writeHeartbeat()
        settings = nextSettings
        previous = capture(Date(), settings, locked)
        if observing { syncTimer() }
    }

    private func syncTimer() {
        guard settings.isEnabled, settings.trackingEnabled else {
            timer?.invalidate()
            timer = nil
            media?.stop()
            return
        }
        if settings.mediaTrackingEnabled { media?.start() } else { media?.stop() }
        if timer == nil { startTimer() }
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeHeartbeat() }
        }
        timer.tolerance = 1
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
        defer {
            previous = current
            lastHeartbeat = now
        }
        recordMedia(now: now)
        guard var sample = previous else { return }
        let duration = now.timeIntervalSince(sample.event.startedAt)
        guard duration > 0, duration <= 30 else { return }
        sample.event.duration = duration
        if let before = sample.counters, let after = current?.counters {
            let signals = after.signals(since: before)
            sample.event.signals = signals.isEmpty ? nil : signals
        }
        writer.submit(sample)
    }

    func recordMedia(now: Date, playing: [AttentionPlayback]? = nil) {
        guard settings.isEnabled, settings.trackingEnabled, settings.mediaTrackingEnabled else {
            mediaSegments.removeAll()
            return
        }
        let items = playing ?? media?.current(now: now) ?? []
        let since = lastHeartbeat.map { min(now.timeIntervalSince($0), 30) } ?? 0
        var active = Set<String>()
        for item in items {
            let key = item.key
            active.insert(key)
            var segment =
                mediaSegments[key].flatMap { now.timeIntervalSince($0.lastSeen) <= 60 ? $0 : nil }
                ?? (
                    id: "media:\(UUID().uuidString)", startedAt: now.addingTimeInterval(-since),
                    lastSeen: now
                )
            segment.lastSeen = now
            mediaSegments[key] = segment
            let duration = now.timeIntervalSince(segment.startedAt)
            guard duration > 0 else { continue }
            writer.submit(
                AttentionHeartbeatSample(
                    event: AttentionEvent(
                        id: segment.id, startedAt: segment.startedAt, duration: duration,
                        source: .media, appName: item.media.service, bundleID: item.bundleID,
                        media: item.media),
                    processID: 0, captureWindowTitle: false))
        }
        mediaSegments = mediaSegments.filter { active.contains($0.key) }
    }

    private static func capture(
        now: Date, settings: AttentionSettings, locked: Bool
    ) -> AttentionHeartbeatSample? {
        guard settings.isEnabled, settings.trackingEnabled,
            let app = NSWorkspace.shared.frontmostApplication
        else { return nil }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        let away = app.bundleIdentifier.map(AttentionCatalog.awayBundleIDs.contains) ?? false
        let presence: AttentionPresence =
            locked || away ? .locked : idleSeconds >= settings.idleThreshold ? .idle : .active
        let context = AttentionContextBoard.shared.context(for: app.bundleIdentifier, now: now)
        return AttentionHeartbeatSample(
            event: AttentionEvent(
                startedAt: now, duration: 0, source: .application,
                presence: presence, appName: app.localizedName, bundleID: app.bundleIdentifier,
                windowTitle: context?.windowTitle, tags: context?.tags),
            processID: app.processIdentifier,
            captureWindowTitle: settings.windowTitlesEnabled && context?.windowTitle == nil,
            counters: AttentionInputCounters.read())
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
            guard settings.isEnabled, settings.trackingEnabled else { return }
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
