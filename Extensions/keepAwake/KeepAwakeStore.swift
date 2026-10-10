import AppKit
import EdithExtensionSupport
import Foundation
import IOKit.pwr_mgt

enum KeepAwakeKeys {
    static let enabled = "keepAwakeEnabled"
}

@MainActor
final class KeepAwakeStore {
    private(set) var preventingSleep = false
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private let createAssertion: () -> IOPMAssertionID?
    private let assertionIsActive: (IOPMAssertionID) -> Bool
    private let releaseAssertion: (IOPMAssertionID) -> Void
    private var assertionID: IOPMAssertionID?
    private var settingsObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var reconciliationTimer: Timer?
    private var stopped = false

    convenience init() {
        self.init(defaults: .standard)
    }

    init(
        defaults: UserDefaults,
        notificationCenter: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        reconciliationInterval: TimeInterval? = 30,
        createAssertion: @escaping () -> IOPMAssertionID? = KeepAwakeStore.createDisplayAssertion,
        assertionIsActive: @escaping (IOPMAssertionID) -> Bool = KeepAwakeStore
            .displayAssertionIsActive,
        releaseAssertion: @escaping (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) }
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.workspaceNotifications = workspaceNotifications
        self.createAssertion = createAssertion
        self.assertionIsActive = assertionIsActive
        self.releaseAssertion = releaseAssertion
        settingsObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncPreventSleep() }
        }
        wakeObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncPreventSleep() }
        }
        if let reconciliationInterval {
            let timer = Timer(timeInterval: reconciliationInterval, repeats: true) {
                [weak self] _ in
                Task { @MainActor in self?.syncPreventSleep() }
            }
            timer.tolerance = reconciliationInterval / 5
            reconciliationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        syncPreventSleep()
    }

    static func fixture(defaults: UserDefaults) -> KeepAwakeStore {
        var nextAssertion: IOPMAssertionID = 0
        var activeAssertions: Set<IOPMAssertionID> = []
        return KeepAwakeStore(
            defaults: defaults, notificationCenter: NotificationCenter(),
            workspaceNotifications: NotificationCenter(), reconciliationInterval: nil,
            createAssertion: {
                nextAssertion += 1
                activeAssertions.insert(nextAssertion)
                return nextAssertion
            },
            assertionIsActive: { activeAssertions.contains($0) },
            releaseAssertion: { activeAssertions.remove($0) })
    }

    func syncPreventSleep() {
        guard !stopped else { return }
        let want =
            defaults.bool(forKey: KeepAwakeKeys.enabled)
            && defaults.bool(forKey: AppStorageKeys.General.preventSleep)
        guard want else {
            releaseCurrentAssertion()
            return
        }
        if let assertionID, assertionIsActive(assertionID) {
            preventingSleep = true
            return
        }
        releaseCurrentAssertion()
        assertionID = createAssertion()
        preventingSleep = assertionID != nil
    }

    func shutdown() {
        stopped = true
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
        if let settingsObserver { notificationCenter.removeObserver(settingsObserver) }
        settingsObserver = nil
        if let wakeObserver { workspaceNotifications.removeObserver(wakeObserver) }
        wakeObserver = nil
        releaseCurrentAssertion()
    }

    private func releaseCurrentAssertion() {
        if let assertionID { releaseAssertion(assertionID) }
        assertionID = nil
        preventingSleep = false
    }

    private nonisolated static func createDisplayAssertion() -> IOPMAssertionID? {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Edith: Keep Awake is on" as CFString,
            &assertion)
        return result == kIOReturnSuccess ? assertion : nil
    }

    private nonisolated static func displayAssertionIsActive(_ assertion: IOPMAssertionID) -> Bool {
        guard
            let properties = IOPMAssertionCopyProperties(assertion)?.takeRetainedValue()
                as? [String: Any]
        else { return false }
        return properties[kIOPMAssertionLevelKey] as? Int == kIOPMAssertionLevelOn
    }
}
