import AppKit
import Carbon.HIToolbox
import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
final class KeystrokeHighlightRuntime: FeatureModule {
    private(set) var queue = KeystrokeHighlightQueue(
        maximumVisible: KeystrokeHighlightSettings.maximumVisible)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var panel: KeystrokeHighlightPanel?
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        start()
    }

    var entries: [KeystrokeHighlightEntry] { queue.entries }

    func syncSettings() {
        guard !entries.isEmpty else { return }
        movePanelToPointerScreen()
    }

    func shutdown() {
        uninstallEventTap()
        healthTimer?.invalidate()
        healthTimer = nil
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
        queue = KeystrokeHighlightQueue(
            maximumVisible: KeystrokeHighlightSettings.maximumVisible)
        panel?.orderOut(nil)
        panel = nil
        setRuntimeState(active: false, error: "")
    }

    private func start() {
        guard CGPreflightListenEventAccess() else {
            setRuntimeState(
                active: false,
                error: "Input Monitoring is required before key presses can be shown.")
            return
        }
        guard installEventTap() else {
            setRuntimeState(
                active: false,
                error:
                    "The keyboard event monitor could not be started. Restart Edith and try again.")
            return
        }
        setRuntimeState(active: true, error: "")
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let eventTap = self.eventTap else { return }
                if !CGEvent.tapIsEnabled(tap: eventTap) {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }
        }
    }

    private func installEventTap() -> Bool {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let runtime = Unmanaged<KeystrokeHighlightRuntime>.fromOpaque(refcon)
                .takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor in runtime.reenableEventTap() }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown, !IsSecureEventInputEnabled() else {
                return Unmanaged.passUnretained(event)
            }
            guard let labels = KeystrokeHighlightRuntime.labels(from: event) else {
                return Unmanaged.passUnretained(event)
            }
            Task { @MainActor in
                runtime.show(labels: labels)
            }
            return Unmanaged.passUnretained(event)
        }
        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.eventTap = eventTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private func uninstallEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        runLoopSource = nil
    }

    private func reenableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func show(labels: [String]) {
        let duration = max(
            KeystrokeHighlightSettings.durationRange.lowerBound,
            min(
                KeystrokeHighlightSettings.durationRange.upperBound,
                SharedDefaults.store.object(forKey: AppStorageKeys.KeystrokeHighlight.duration)
                    as? Double ?? KeystrokeHighlightSettings.defaultDuration))
        guard let entry = queue.append(keys: labels, duration: duration) else { return }
        showPanel()
        scheduleExpiry(entry)
    }

    private func showPanel() {
        movePanelToPointerScreen()
        panel?.orderFrontRegardless()
    }

    private func movePanelToPointerScreen() {
        guard let screen = screenUnderPointer() else { return }
        if panel == nil {
            panel = KeystrokeHighlightPanel(
                screen: screen, rootView: KeystrokeHighlightOverlay(runtime: self))
        } else if panel?.frame != screen.frame {
            panel?.setFrame(screen.frame, display: true)
        }
    }

    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    private func scheduleExpiry(_ entry: KeystrokeHighlightEntry) {
        let delay = max(0, entry.expiresAt.timeIntervalSinceNow)
        let id = entry.id
        expiryTasks[id]?.cancel()
        expiryTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                self.queue.remove(id: id)
            }
            self.expiryTasks[id] = nil
            if self.entries.isEmpty { self.panel?.orderOut(nil) }
        }
    }

    private func setRuntimeState(active: Bool, error: String) {
        SharedDefaults.store.set(active, forKey: AppStorageKeys.KeystrokeHighlight.runtimeActive)
        SharedDefaults.store.set(error, forKey: AppStorageKeys.KeystrokeHighlight.runtimeError)
    }

    nonisolated static func labels(from event: CGEvent) -> [String]? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers
        return KeystrokeLabelResolver.labels(
            keyCode: keyCode, characters: characters,
            unmodifiedCharacters: unmodifiedCharacters(keyCode: keyCode),
            modifiers: modifiers(from: event.flags))
    }

    nonisolated static func modifiers(from flags: CGEventFlags) -> KeystrokeModifiers {
        var modifiers: KeystrokeModifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        return modifiers
    }

    private nonisolated static func unmodifiedCharacters(keyCode: UInt16) -> String? {
        guard
            let event = CGEvent(
                keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)
        else { return nil }
        event.flags = []
        return NSEvent(cgEvent: event)?.charactersIgnoringModifiers
    }
}
