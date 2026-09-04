import AppKit
import ApplicationServices
import CoreGraphics
import EdithKit
import Foundation

@MainActor
final class AttentionTrackingService {
    private struct HeartbeatSnapshot: Sendable {
        let startedAt: Date
        let duration: TimeInterval
        let presence: AttentionPresence
        let appName: String?
        let bundleID: String?
        let pid: pid_t
        let wantsWindowTitle: Bool
    }

    private let repository: AttentionRepository
    private var settings: AttentionSettings
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastHeartbeatAt = Date()
    private var locked = false
    private var appendTask: Task<Void, Never>?

    init(repository: AttentionRepository = AttentionRepository()) {
        self.repository = repository
        settings = repository.loadSettings()
        installObservers()
        startTimer()
    }

    func shutdown() {
        writeHeartbeat()
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        appendTask?.cancel()
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
        let snapshot = HeartbeatSnapshot(
            startedAt: lastHeartbeatAt, duration: duration, presence: presence,
            appName: app.localizedName, bundleID: app.bundleIdentifier,
            pid: app.processIdentifier, wantsWindowTitle: settings.windowTitlesEnabled)
        lastHeartbeatAt = now
        let repository = repository
        let previous = appendTask
        appendTask = Task.detached(priority: .utility) {
            await previous?.value
            let title = snapshot.wantsWindowTitle ? Self.focusedWindowTitle(pid: snapshot.pid) : nil
            let event = AttentionEvent(
                startedAt: snapshot.startedAt, duration: snapshot.duration, source: .application,
                presence: snapshot.presence, appName: snapshot.appName,
                bundleID: snapshot.bundleID, windowTitle: title)
            try? repository.append(event)
        }
    }

    private nonisolated static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
            let window = windowValue
        else { return nil }
        var titleValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success
        else { return nil }
        return (titleValue as? String).map { String($0.prefix(500)) }
    }

}
