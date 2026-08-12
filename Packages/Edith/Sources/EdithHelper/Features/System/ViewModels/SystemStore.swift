import AppKit
import ApplicationServices
import CoreGraphics
import EdithKit
import IOKit.pwr_mgt
import Observation
import SwiftUI

@MainActor
@Observable
final class SystemStore: FeatureModule {

    private(set) var preventingSleep = false
    private var assertionID: IOPMAssertionID = 0

    enum CleaningPhase { case idle, arming, cleaning }
    private(set) var phase = CleaningPhase.idle
    private(set) var armingCountdown = 0
    private(set) var failsafeRemaining = 0
    private(set) var hasInputMonitoring = false
    private(set) var hasAccessibility = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var armTimer: Timer?
    private var failsafeTimer: Timer?
    private var healthTimer: Timer?
    private var overlays: [NSWindow] = []
    private var terminateObserver: NSObjectProtocol?

    private let armingSeconds = 3
    private let failsafeSeconds = 60

    init() {
        refreshPermissions()
        if SharedDefaults.store.bool(forKey: AppStorageKeys.General.preventSleep) {
            enableSleepPrevention()
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.shutdown() }
        }
    }

    func shutdown() {
        stopCleaning()
        if preventingSleep {
            IOPMAssertionRelease(assertionID)
            preventingSleep = false
        }
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
    }

    func setPreventSleep(_ on: Bool) {
        SharedDefaults.store.set(on, forKey: AppStorageKeys.General.preventSleep)
        on ? enableSleepPrevention() : disableSleepPrevention()
    }

    func syncPreventSleep() {
        let want = SharedDefaults.store.bool(forKey: AppStorageKeys.General.preventSleep)
        guard want != preventingSleep else { return }
        want ? enableSleepPrevention() : disableSleepPrevention()
    }

    private func enableSleepPrevention() {
        guard !preventingSleep else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Edith: Prevent Sleep is on" as CFString,
            &assertionID)
        preventingSleep = (result == kIOReturnSuccess)
    }

    private func disableSleepPrevention() {
        guard preventingSleep else { return }
        IOPMAssertionRelease(assertionID)
        preventingSleep = false
    }

    func refreshPermissions() {
        hasInputMonitoring = CGPreflightListenEventAccess()
        hasAccessibility = AXIsProcessTrusted()
    }

    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    func requestInputMonitoring() {
        PermissionPromptTracker.record()
        CGRequestListenEventAccess()
        openInputMonitoringSettings()
        IPC.post(IPC.Name.requestPermissionsRefresh)
        recheckSoon()
    }

    func requestAccessibility() {
        PermissionPromptTracker.record()
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openAccessibilitySettings()
        IPC.post(IPC.Name.requestPermissionsRefresh)
        recheckSoon()
    }

    func openInputMonitoringSettings() {
        NSWorkspace.shared.open(
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    private func recheckSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshPermissions()
            IPC.post(IPC.Name.requestPermissionsRefresh)
        }
    }

    func beginCleaning() {
        refreshPermissions()
        guard phase == .idle else { return }
        guard hasInputMonitoring else {
            requestInputMonitoring()
            return
        }
        guard hasAccessibility else {
            requestAccessibility()
            return
        }
        dismissPanel()
        phase = .arming
        armingCountdown = armingSeconds
        showOverlays()
        armTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.armingCountdown -= 1
                if self.armingCountdown <= 0 {
                    timer.invalidate()
                    self.startCleaning()
                }
            }
        }
    }

    private func startCleaning() {
        guard installEventTap() else {
            stopCleaning()
            return
        }
        phase = .cleaning
        failsafeRemaining = failsafeSeconds
        failsafeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.failsafeRemaining -= 1
                if self.failsafeRemaining <= 0 {
                    timer.invalidate()
                    self.stopCleaning()
                }
            }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let tap = self.eventTap else { return }
                if !CGEvent.tapIsEnabled(tap: tap) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
        }
    }

    func stopCleaning() {
        uninstallEventTap()
        armTimer?.invalidate()
        failsafeTimer?.invalidate()
        healthTimer?.invalidate()
        armTimer = nil
        failsafeTimer = nil
        healthTimer = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        phase = .idle
    }

    private func showOverlays() {
        guard overlays.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = CleaningOverlayWindow(
                screen: screen,
                rootView: CleaningOverlayView(store: self))
            window.orderFrontRegardless()
            overlays.append(window)
        }
    }

    private func installEventTap() -> Bool {
        func bit(_ type: CGEventType) -> CGEventMask { CGEventMask(1) << type.rawValue }
        let mask: CGEventMask =
            bit(.keyDown) | bit(.keyUp) | bit(.flagsChanged)
            | (CGEventMask(1) << 14)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let store = Unmanaged<SystemStore>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = store.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return nil
            }
            return nil
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func uninstallEventTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        runLoopSource = nil
    }
}
