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
    private var server: AttentionIngestionServer?
    private var lastBackupAt = Date.distantPast

    init(repository: AttentionRepository = AttentionRepository()) {
        self.repository = repository
        settings = repository.loadSettings()
        installObservers()
        startTimer()
        startServer()
    }

    func shutdown() {
        writeHeartbeat()
        timer?.invalidate()
        timer = nil
        server?.stop()
        server = nil
        backupIfNeeded(force: true)
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    func sync(_ nextSettings: AttentionSettings) {
        let serverChanged =
            settings.browserTrackingEnabled != nextSettings.browserTrackingEnabled
            || settings.serverPort != nextSettings.serverPort
            || settings.serverToken != nextSettings.serverToken
        writeHeartbeat()
        settings = nextSettings
        if serverChanged {
            server?.stop()
            server = nil
            startServer()
        }
        backupIfNeeded(force: true)
    }

    private func startTimer() {
        lastHeartbeatAt = Date()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeHeartbeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func startServer() {
        guard settings.browserTrackingEnabled else { return }
        let server = AttentionIngestionServer(repository: repository, settings: settings)
        try? server.start()
        self.server = server
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
        backupIfNeeded()
        guard settings.trackingEnabled, duration > 0.2,
            let app = NSWorkspace.shared.frontmostApplication
        else {
            lastHeartbeatAt = now
            return
        }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        let presence: AttentionPresence =
            locked ? .locked : idleSeconds >= settings.idleThreshold ? .idle : .active
        let title =
            settings.windowTitlesEnabled ? focusedWindowTitle(pid: app.processIdentifier) : nil
        let event = AttentionEvent(
            startedAt: lastHeartbeatAt, duration: duration, source: .application,
            presence: presence, appName: app.localizedName, bundleID: app.bundleIdentifier,
            windowTitle: title)
        try? repository.append(event)
        lastHeartbeatAt = now
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
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

    private func backupIfNeeded(force: Bool = false) {
        guard settings.iCloudBackupEnabled,
            force || Date().timeIntervalSince(lastBackupAt) >= 900
        else { return }
        lastBackupAt = Date()
        DispatchQueue.global(qos: .utility).async {
            _ = try? AttentionCloudBackup().backup()
        }
    }
}
