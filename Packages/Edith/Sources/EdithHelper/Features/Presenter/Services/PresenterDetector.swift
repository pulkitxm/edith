import AppKit
import CoreGraphics
import EdithKit
import Foundation

struct PresenterSystem {
    var runningBundleIDs: () -> Set<String>
    var remoteSessionActive: () -> Bool
    var displayMirrored: () -> Bool
    var announce: () -> Void

    static var live: PresenterSystem {
        PresenterSystem(
            runningBundleIDs: {
                Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            },
            remoteSessionActive: {
                guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else {
                    return false
                }
                return (info["kCGSSessionOnConsoleKey"] as? Bool) == false
            },
            displayMirrored: {
                var count: UInt32 = 0
                CGGetActiveDisplayList(0, nil, &count)
                guard count > 0 else { return false }
                var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
                CGGetActiveDisplayList(count, &displays, &count)
                return displays.contains { CGDisplayIsInMirrorSet($0) != 0 }
            },
            announce: { IPC.post(IPC.Name.presenterAutoActiveChanged) })
    }
}

@MainActor
final class PresenterDetector: FeatureModule {
    let scanner: PresenterScanner
    private let system: PresenterSystem
    private let defaults: UserDefaults
    private let monitoring: Bool

    private var gateApps: Set<String>
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?
    private var windowScanTimer: DispatchSourceTimer?
    private var sessionTimer: Timer?
    private let scanQueue = DispatchQueue(label: "presenterDetector.scan", qos: .utility)

    private var signals: PresenterSignals
    private(set) var publishedActive: Bool
    private(set) var publishedReason: String?

    convenience init() {
        self.init(
            scanner: PresenterScanner(), system: .live, defaults: SharedDefaults.store,
            monitoring: true)
    }

    init(
        scanner: PresenterScanner, system: PresenterSystem, defaults: UserDefaults,
        monitoring: Bool
    ) {
        self.scanner = scanner
        self.system = system
        self.defaults = defaults
        self.monitoring = monitoring
        signals = PresenterSignals(
            paused: defaults.bool(forKey: AppStorageKeys.Presenter.autoPaused))
        publishedActive = defaults.bool(forKey: AppStorageKeys.Presenter.autoActive)
        publishedReason = defaults.string(forKey: AppStorageKeys.Presenter.autoReason)
        gateApps = system.runningBundleIDs().intersection(PresenterRules.watchedBundleIDs)

        if monitoring {
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated { self?.handleLaunch(note) }
            }
            terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated { self?.handleTerminate(note) }
            }
            screenParamsObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshMirroring()
                    self?.evaluate()
                }
            }
        }

        syncWindowScanTimer()
        syncSessionTimer()
        refreshMirroring()
        evaluate()
    }

    func applySettings() {
        syncSessionTimer()
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
        signals.pause()
        defaults.set(true, forKey: AppStorageKeys.Presenter.autoPaused)
        evaluate()
    }

    func applyScan(_ outcome: PresenterScan) {
        guard scanning else { return }
        signals.windowReason = outcome.windowReason
        signals.recording = outcome.recordingHit
        evaluate(scan: true)
    }

    func tickSession() {
        signals.sharing = detectsSharing && system.remoteSessionActive()
        refreshMirroring()
        evaluate()
    }

    private var scanning: Bool { !gateApps.isEmpty }

    private var detectsSharing: Bool {
        defaults.object(forKey: AppStorageKeys.Presenter.detectScreenSharing) as? Bool ?? true
    }

    private func handleLaunch(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let id = app.bundleIdentifier, PresenterRules.watchedBundleIDs.contains(id)
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
            signals.windowReason = nil
            signals.recording = false
            evaluate()
        }
    }

    private func syncWindowScanTimer() {
        guard monitoring, scanning else {
            windowScanTimer?.cancel()
            windowScanTimer = nil
            return
        }
        guard windowScanTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: scanQueue)
        timer.schedule(deadline: .now(), repeating: 3, leeway: .seconds(1))
        let scanner = scanner
        timer.setEventHandler { [weak self] in
            let outcome = scanner.scan()
            Task { @MainActor in self?.applyScan(outcome) }
        }
        timer.resume()
        windowScanTimer = timer
    }

    private func syncSessionTimer() {
        guard detectsSharing else {
            sessionTimer?.invalidate()
            sessionTimer = nil
            if signals.sharing {
                signals.sharing = false
                evaluate()
            }
            return
        }
        guard monitoring, sessionTimer == nil else { return }
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSession() }
        }
        sessionTimer?.tolerance = 5
        tickSession()
    }

    private func refreshMirroring() {
        let detectMirroring =
            defaults.object(forKey: AppStorageKeys.Presenter.detectMirroring) as? Bool ?? true
        signals.mirroring = detectMirroring && system.displayMirrored()
    }

    private func evaluate(scan: Bool = false) {
        let wasPaused = signals.paused
        let verdict = signals.evaluate(completedScan: scan || !scanning)
        if wasPaused, !signals.paused {
            defaults.set(false, forKey: AppStorageKeys.Presenter.autoPaused)
        }
        publish(active: verdict.active, reason: verdict.reason)
    }

    private func publish(active: Bool, reason: String?) {
        guard active != publishedActive || reason != publishedReason else { return }
        publishedActive = active
        publishedReason = reason
        defaults.set(active, forKey: AppStorageKeys.Presenter.autoActive)
        if let reason {
            defaults.set(reason, forKey: AppStorageKeys.Presenter.autoReason)
        } else {
            defaults.removeObject(forKey: AppStorageKeys.Presenter.autoReason)
        }
        system.announce()
    }
}
