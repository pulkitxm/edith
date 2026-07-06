import AppKit
import CoreGraphics
import Darwin
import EdithKit
import Foundation

@MainActor
final class PresenterDetector: FeatureModule {
    static let watchedBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.QuickTimePlayerX",
    ]

    private var gateApps: Set<String> = []
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?
    private var windowScanTimer: DispatchSourceTimer?
    private var sessionTimer: Timer?

    private var debouncer = PresenterDebouncer()
    private var currentReason: String?
    private var paused: Bool

    private var windowHit = false
    private var windowReason: String?
    private var recordingHit = false
    private var sharingHit = false
    private var mirrorHit = false

    private var publishedActive = false
    private var publishedReason: String?

    init() {
        paused = SharedDefaults.store.bool(forKey: "presenterAutoPaused")
        gateApps = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            .intersection(Self.watchedBundleIDs)

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleLaunch(note) }
        }
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleTerminate(note) }
        }
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMirroring() }
        }

        syncWindowScanTimer()
        startSessionTimer()
        checkMirroring()
        evaluate()
    }

    func shutdown() {
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
        }
        if let screenParamsObserver {
            NotificationCenter.default.removeObserver(screenParamsObserver)
        }
        launchObserver = nil
        terminateObserver = nil
        screenParamsObserver = nil
        windowScanTimer?.cancel()
        windowScanTimer = nil
        sessionTimer?.invalidate()
        sessionTimer = nil
        publish(active: false, reason: nil)
    }

    func pauseUntilShareEnds() {
        paused = true
        SharedDefaults.store.set(true, forKey: "presenterAutoPaused")
        evaluate()
    }

    private func handleLaunch(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let id = app.bundleIdentifier, Self.watchedBundleIDs.contains(id)
        else { return }
        gateApps.insert(id)
        syncWindowScanTimer()
    }

    private func handleTerminate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let id = app.bundleIdentifier
        else { return }
        gateApps.remove(id)
        syncWindowScanTimer()
        if gateApps.isEmpty {
            windowHit = false
            windowReason = nil
            recordingHit = false
            evaluate()
        }
    }

    private func syncWindowScanTimer() {
        guard !gateApps.isEmpty else {
            windowScanTimer?.cancel()
            windowScanTimer = nil
            return
        }
        guard windowScanTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scanWindows() }
        }
        timer.resume()
        windowScanTimer = timer
    }

    private func startSessionTimer() {
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick10s() }
        }
    }

    private func scanWindows() {
        let titlesAvailable = CGPreflightScreenCaptureAccess()
        windowReason = PresenterRules.firstMatch(
            in: Self.currentWindows(), titlesAvailable: titlesAvailable)
        windowHit = windowReason != nil

        let detectRecording =
            SharedDefaults.store.object(forKey: "presenterDetectRecording") as? Bool ?? true
        recordingHit = detectRecording && Self.isProcessRunning(named: "screencapture")

        evaluate()
    }

    private func tick10s() {
        let detectSharing =
            SharedDefaults.store.object(forKey: "presenterDetectScreenSharing") as? Bool ?? true
        sharingHit = detectSharing && Self.isRemoteSessionActive()
        checkMirroring()
        evaluate()
    }

    private func checkMirroring() {
        let detectMirroring =
            SharedDefaults.store.object(forKey: "presenterDetectMirroring") as? Bool ?? true
        mirrorHit = detectMirroring && Self.isAnyDisplayMirrored()
        evaluate()
    }

    private func evaluate() {
        let hit = windowHit || recordingHit || sharingHit || mirrorHit
        if paused {
            guard !PresenterPauseGate.stillPaused(hit: hit) else {
                publish(active: false, reason: nil)
                return
            }
            paused = false
            SharedDefaults.store.set(false, forKey: "presenterAutoPaused")
        }
        let reason =
            windowReason
            ?? (recordingHit ? "Screen recording detected" : nil)
            ?? (sharingHit ? "Screen Sharing detected" : nil)
            ?? (mirrorHit ? "Mirrored display detected" : nil)
        let active = debouncer.record(hit: hit)
        currentReason = active ? (reason ?? currentReason) : nil
        publish(active: active, reason: currentReason)
    }

    private func publish(active: Bool, reason: String?) {
        guard active != publishedActive || reason != publishedReason else { return }
        publishedActive = active
        publishedReason = reason
        let d = SharedDefaults.store
        d.set(active, forKey: "presenterAutoActive")
        if let reason {
            d.set(reason, forKey: "presenterAutoReason")
        } else {
            d.removeObject(forKey: "presenterAutoReason")
        }
        IPC.post(IPC.Name.presenterAutoActiveChanged)
    }

    private static func currentWindows() -> [PresenterWindowInfo] {
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String else { return nil }
            let title = info[kCGWindowName as String] as? String ?? ""
            let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = bounds["Width"] as? Double ?? 0
            let height = bounds["Height"] as? Double ?? 0
            return PresenterWindowInfo(ownerName: owner, title: title, width: width, height: height)
        }
    }

    private static func isProcessRunning(named target: String) -> Bool {
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size)
        let actual = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, size)
        guard actual > 0 else { return false }
        let count = Int(actual) / MemoryLayout<pid_t>.size
        for pid in pids.prefix(count) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 64)
            let len = proc_name(pid, &buffer, UInt32(buffer.count))
            if len > 0, String(cString: buffer) == target { return true }
        }
        return false
    }

    private static func isRemoteSessionActive() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["kCGSSessionOnConsoleKey"] as? Bool) == false
    }

    private static func isAnyDisplayMirrored() -> Bool {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays.contains { CGDisplayIsInMirrorSet($0) != 0 }
    }
}
