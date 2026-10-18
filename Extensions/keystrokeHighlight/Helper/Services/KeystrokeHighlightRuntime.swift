#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
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
    private var expiryTasks: [UUID: UUID] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    private let fixture: WorkerFixtureAdmission?
    var systemResourceCount: Int {
        (eventTap == nil ? 0 : 1) + (runLoopSource == nil ? 0 : 1) + (healthTimer == nil ? 0 : 1)
            + (panel == nil ? 0 : 1)
    }

    convenience init() { self.init(fixture: nil) }

    init(fixture: WorkerFixtureAdmission?) {
        precondition(fixture == nil || fixture?.extensionID == "keystrokeHighlight")
        self.fixture = fixture
        start()
    }

    var entries: [KeystrokeHighlightEntry] { queue.entries }

    func syncSettings() {
        guard !stopped else { return }
        guard fixture == nil else { return }
        guard !entries.isEmpty else { return }
        movePanelToPointerScreen()
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        uninstallEventTap()
        healthTimer?.invalidate()
        healthTimer = nil
        tasks.values.forEach { $0.cancel() }
        queue = KeystrokeHighlightQueue(
            maximumVisible: KeystrokeHighlightSettings.maximumVisible)
        panel?.orderOut(nil)
        panel = nil
        setRuntimeState(active: false, error: "")
    }

    private func start() {
        guard !stopped else { return }
        if fixture != nil { setRuntimeState(active: true, error: ""); return }
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
            MainActor.assumeIsolated {
                self?.startWork { [weak self] in self?.reenableEventTap() }
            }
        }
        healthTimer?.tolerance = 2
    }

    private func installEventTap() -> Bool {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let runtime = Unmanaged<KeystrokeHighlightRuntime>.fromOpaque(refcon)
                .takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated {
                    runtime.startWork { runtime.reenableEventTap() }
                }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown, !IsSecureEventInputEnabled() else {
                return Unmanaged.passUnretained(event)
            }
            guard
                let labels = MainActor.assumeIsolated({
                    KeystrokeEventLabelReader.labels(from: event)
                })
            else {
                return Unmanaged.passUnretained(event)
            }
            MainActor.assumeIsolated {
                runtime.startWork { runtime.show(labels: labels) }
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
        guard !stopped, let eventTap else { return }
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
        if let token = expiryTasks[id] { tasks[token]?.cancel() }
        let token = UUID()
        expiryTasks[id] = token
        tasks[token] = Task { @MainActor [self] in
            defer {
                tasks[token] = nil
                if expiryTasks[id] == token { expiryTasks[id] = nil }
            }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !stopped, !Task.isCancelled, expiryTasks[id] == token else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                self.queue.remove(id: id)
            }
            if self.entries.isEmpty { self.panel?.orderOut(nil) }
        }
    }

    private func startWork(_ operation: @escaping @MainActor () -> Void) {
        guard !stopped else { return }
        let id = UUID()
        tasks[id] = Task { [self] in
            defer { tasks[id] = nil }
            guard !stopped, !Task.isCancelled else { return }
            operation()
        }
    }

    func shutdownAndWait() async {
        shutdown()
        for task in Array(tasks.values) { await task.value }
    }

    private func setRuntimeState(active: Bool, error: String) {
        SharedDefaults.store.set(active, forKey: AppStorageKeys.KeystrokeHighlight.runtimeActive)
        SharedDefaults.store.set(error, forKey: AppStorageKeys.KeystrokeHighlight.runtimeError)
    }

}
