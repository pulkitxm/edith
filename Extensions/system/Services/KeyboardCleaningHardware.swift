import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension KeyboardCleaningEnvironment {
    @MainActor static var live: Self {
        let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> KeyboardCleaningTimer = {
            interval, action in
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                MainActor.assumeIsolated { action() }
            }
            return KeyboardCleaningTimer { timer.invalidate() }
        }
        if ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil {
            return .init(
                permissions: { (true, true) }, requestInputMonitoring: {}, requestAccessibility: {},
                installTap: { true }, removeTap: {}, ensureTap: {}, showOverlays: { _ in true },
                hideOverlays: {}, schedule: schedule)
        }
        let hardware = KeyboardCleaningHardware()
        return .init(
            permissions: { (CGPreflightListenEventAccess(), AXIsProcessTrusted()) },
            requestInputMonitoring: { _ = CGRequestListenEventAccess() },
            requestAccessibility: {
                _ = AXIsProcessTrustedWithOptions(
                    ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }, installTap: { hardware.installTap() }, removeTap: { hardware.removeTap() },
            ensureTap: { hardware.ensureTap() }, showOverlays: { hardware.showOverlays($0) },
            hideOverlays: { hardware.hideOverlays() }, schedule: schedule)
    }
}

@MainActor final class KeyboardCleaningHardware {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var overlays: [CleaningOverlayWindow] = []

    func showOverlays(_ store: KeyboardCleaning) -> Bool {
        guard overlays.isEmpty else { return true }
        for screen in NSScreen.screens {
            let window = CleaningOverlayWindow(
                screen: screen, rootView: CleaningOverlayView(store: store))
            window.orderFrontRegardless()
            overlays.append(window)
        }
        return !overlays.isEmpty
    }

    func hideOverlays() {
        for window in overlays {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        overlays.removeAll()
    }

    func installTap() -> Bool {
        guard eventTap == nil else { return true }
        let mask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << 14)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated {
                    Unmanaged<KeyboardCleaningHardware>.fromOpaque(context).takeUnretainedValue()
                        .ensureTap()
                }
            }
            return nil
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        eventTap = tap; runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func ensureTap() {
        if let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    func removeTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        runLoopSource = nil; eventTap = nil
    }
}
