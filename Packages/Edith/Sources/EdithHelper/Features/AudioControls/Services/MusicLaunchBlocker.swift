import AppKit
import EdithKit
import Foundation

enum MusicLaunchBlockPolicy {
    static let mediaKeyCodes: Set<Int> = [16, 17, 18, 19, 20]

    static func shouldArm(data1: Int) -> Bool {
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let state = (data1 & 0x0000_FF00) >> 8
        return state == 10 && mediaKeyCodes.contains(keyCode)
    }

    static func shouldBlock(lastMediaKeyAt: Date?, launchAt: Date, window: TimeInterval = 2) -> Bool
    {
        guard let lastMediaKeyAt else { return false }
        let elapsed = launchAt.timeIntervalSince(lastMediaKeyAt)
        return elapsed >= 0 && elapsed <= window
    }
}

@MainActor
final class MusicLaunchBlocker {
    private let workspace: NSWorkspace
    private let now: () -> Date
    private let replacement: () -> Void
    private var monitor: Any?
    private var launchObserver: NSObjectProtocol?
    private var lastMediaKeyAt: Date?
    private var lastReplacementAt: Date?
    private var active = false

    init(
        workspace: NSWorkspace = .shared, now: @escaping () -> Date = Date.init,
        replacement: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.now = now
        self.replacement = replacement
    }

    func start() {
        guard !active else { return }
        active = true
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) {
            [weak self] event in
            guard event.subtype.rawValue == 8,
                MusicLaunchBlockPolicy.shouldArm(data1: event.data1)
            else { return }
            Task { @MainActor [weak self] in self?.lastMediaKeyAt = self?.now() }
        }
        launchObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleLaunch(notification) }
        }
    }

    func stop() {
        guard active else { return }
        active = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let launchObserver { workspace.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        lastMediaKeyAt = nil
        lastReplacementAt = nil
    }

    private func handleLaunch(_ notification: Notification) {
        guard active,
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
            let bundleID = app.bundleIdentifier,
            bundleID == "com.apple.Music" || bundleID == "com.apple.iTunes",
            MusicLaunchBlockPolicy.shouldBlock(lastMediaKeyAt: lastMediaKeyAt, launchAt: now())
        else { return }
        lastMediaKeyAt = nil
        app.terminate()
        Task { @MainActor [weak app] in
            try? await Task.sleep(for: .milliseconds(350))
            if app?.isTerminated == false { app?.forceTerminate() }
        }
        let current = now()
        if let lastReplacementAt, current.timeIntervalSince(lastReplacementAt) < 1 { return }
        lastReplacementAt = current
        replacement()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let launchObserver { workspace.notificationCenter.removeObserver(launchObserver) }
    }
}
