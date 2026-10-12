#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import CoreGraphics
import EdithExtensionSupport

final class FocusDimOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        level = .normal
        isOpaque = true
        backgroundColor = .black
        ignoresMouseEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .fullScreenNone, .ignoresCycle]
        alphaValue = 0
        setFrame(screen.frame, display: true)
    }
}

extension NSScreen {
    var focusDimDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

@MainActor
final class FocusDimEngine: FeatureModule {
    private var overlays: [CGDirectDisplayID: FocusDimOverlayWindow] = [:]
    private var intensity = FocusDimMath.defaultIntensity
    private var animationDuration = FocusDimMath.defaultAnimationDuration
    private var displayMode = FocusDimDisplayMode.perScreenFront
    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var repositionTask: Task<Void, Never>?
    private var repositionGeneration = 0
    private var stopped = false
    private struct RepositionRequest {
        let screenFrames: [(CGDirectDisplayID, CGRect)]
        let frontmostPID: pid_t
        let primaryHeight: CGFloat
        let mode: FocusDimDisplayMode
        let animateIn: Bool
        let generation: Int
    }
    private var pendingReposition: RepositionRequest?
    private var repositionToken: UUID?
    private var repositionJoin: Task<Void, Never>?
    private var animations: Set<UUID> = []
    private var animationEpoch = UUID()
    private var animationWaiter: (UUID, CheckedContinuation<Void, Never>)?
    private var animationDrain: Task<Void, Never>?

    private let fixture: WorkerFixtureAdmission?
    var systemResourceCount: Int {
        overlays.count + (activationObserver == nil ? 0 : 1) + (spaceObserver == nil ? 0 : 1)
            + (screenObserver == nil ? 0 : 1)
    }

    convenience init() { self.init(fixture: nil) }

    init(fixture: WorkerFixtureAdmission?) {
        precondition(fixture == nil || fixture?.extensionID == "focusDim")
        self.fixture = fixture
        loadSettings()
        guard fixture == nil else { return }
        HotKeyRegistrar.install(HotKeyCatalog.focusDim) {
            FocusDimState.setActive(!FocusDimState.isActive())
            IPC.post(IPC.Name.settingsChanged)
        }
        loadSettings()
        rebuildOverlays()
        reposition(animateIn: true)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        activationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition(animateIn: false) }
        }
        spaceObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition(animateIn: false) }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildOverlays()
                self?.reposition(animateIn: true)
            }
        }
    }

    func cancelPendingWork() {
        guard !stopped else { return }
        stopped = true
        repositionGeneration += 1
        retireReposition()
        guard fixture == nil else { return }
        HotKeyRegistrar.clear(HotKeyCatalog.focusDim)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let activationObserver { workspaceCenter.removeObserver(activationObserver) }
        if let spaceObserver { workspaceCenter.removeObserver(spaceObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        activationObserver = nil
        spaceObserver = nil
        screenObserver = nil
    }

    func shutdown() {
        cancelPendingWork()
        guard fixture == nil else { return }
        let windows = Array(overlays.values)
        overlays.removeAll()
        animate(
            { ctx in
                ctx.duration = animationDuration
                windows.forEach { $0.animator().alphaValue = 0 }
            },
            completionHandler: {
                windows.forEach { $0.orderOut(nil) }
            })
    }

    func applySettings() {
        guard !stopped else { return }
        if fixture != nil { loadSettings(); return }
        HotKeyRegistrar.install(HotKeyCatalog.focusDim) {
            FocusDimState.setActive(!FocusDimState.isActive())
            IPC.post(IPC.Name.settingsChanged)
        }
        let previousMode = displayMode
        loadSettings()
        guard FocusDimState.isActive(), CGPreflightScreenCaptureAccess() else {
            let windows = Array(overlays.values)
            animate(
                { ctx in
                    ctx.duration = animationDuration
                    windows.forEach { $0.animator().alphaValue = 0 }
                },
                completionHandler: {
                    guard !FocusDimState.isActive() else { return }
                    windows.forEach { $0.orderOut(nil) }
                })
            return
        }
        if displayMode != previousMode {
            reposition(animateIn: false)
        } else if overlays.values.contains(where: { !$0.isVisible }) {
            reposition(animateIn: true)
        } else {
            animate { ctx in
                ctx.duration = animationDuration
                overlays.values.forEach { $0.animator().alphaValue = self.intensity }
            }
        }
    }

    private func loadSettings() {
        let d = SharedDefaults.store
        intensity = FocusDimMath.clampIntensity(
            d.object(forKey: AppStorageKeys.FocusDim.intensity) as? Double
                ?? FocusDimMath.defaultIntensity)
        animationDuration = FocusDimMath.clampAnimationDuration(
            d.object(forKey: AppStorageKeys.FocusDim.animationDuration) as? Double
                ?? FocusDimMath.defaultAnimationDuration)
        displayMode = FocusDimDisplayMode.from(
            d.string(forKey: AppStorageKeys.FocusDim.otherDisplaysMode))
    }

    private func rebuildOverlays() {
        var next: [CGDirectDisplayID: FocusDimOverlayWindow] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.focusDimDisplayID else { continue }
            if let existing = overlays[id] {
                existing.setFrame(screen.frame, display: true)
                next[id] = existing
            } else {
                next[id] = FocusDimOverlayWindow(screen: screen)
            }
        }
        for (id, window) in overlays where next[id] == nil {
            window.orderOut(nil)
        }
        overlays = next
    }

    private func reposition(animateIn: Bool) {
        guard !stopped else { return }
        repositionGeneration += 1
        let generation = repositionGeneration
        retireReposition()
        guard FocusDimState.isActive(), CGPreflightScreenCaptureAccess() else {
            for overlay in overlays.values {
                overlay.alphaValue = 0
                overlay.orderOut(nil)
            }
            return
        }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        var screenFrames: [(CGDirectDisplayID, CGRect)] = []
        for screen in NSScreen.screens {
            if let displayID = screen.focusDimDisplayID {
                screenFrames.append((displayID, screen.frame))
            }
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        pendingReposition = RepositionRequest(
            screenFrames: screenFrames, frontmostPID: frontmostPID, primaryHeight: primaryHeight,
            mode: displayMode, animateIn: animateIn, generation: generation)
        startPendingReposition()
    }

    private func startPendingReposition() {
        guard !stopped, repositionTask == nil, let request = pendingReposition else { return }
        pendingReposition = nil
        let token = UUID()
        repositionToken = token
        let task = Task.detached(priority: .userInitiated) { [self] in
            let windows = Self.onScreenWindows(primaryHeight: request.primaryHeight)
            guard !Task.isCancelled else { return }
            await applyReposition(
                windows: windows, screenFrames: request.screenFrames,
                frontmostPID: request.frontmostPID, mode: request.mode,
                animateIn: request.animateIn, generation: request.generation)
        }
        repositionTask = task
        repositionJoin = Task { [self, task] in
            await task.value
            guard repositionToken == token else { return }
            repositionTask = nil
            repositionJoin = nil
            repositionToken = nil
            startPendingReposition()
        }
    }

    private func applyReposition(
        windows: [FocusDimWindowInfo], screenFrames: [(CGDirectDisplayID, CGRect)],
        frontmostPID: pid_t, mode: FocusDimDisplayMode, animateIn: Bool, generation: Int
    ) {
        guard !stopped, generation == repositionGeneration else { return }
        var targets: [(FocusDimOverlayWindow, Int?)] = []
        for (id, frame) in screenFrames {
            guard let overlay = overlays[id] else { continue }
            let reference = FocusDimSelection.referenceWindow(
                forScreen: frame, frontmostPID: frontmostPID,
                windowsFrontToBack: windows, mode: mode)
            targets.append((overlay, reference?.windowNumber))
        }

        if animateIn {
            for (overlay, windowNumber) in targets {
                applyOrder(overlay, below: windowNumber)
            }
            animate { ctx in
                ctx.duration = animationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                targets.forEach { $0.0.animator().alphaValue = self.intensity }
            }
            return
        }

        let halfDuration = animationDuration / 2
        animate(
            { ctx in
                ctx.duration = halfDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                targets.forEach { $0.0.animator().alphaValue = 0 }
            },
            completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, generation == self.repositionGeneration else { return }
                    for (overlay, windowNumber) in targets {
                        self.applyOrder(overlay, below: windowNumber)
                    }
                    self.animate { ctx in
                        ctx.duration = halfDuration
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        targets.forEach { $0.0.animator().alphaValue = self.intensity }
                    }
                }
            })
    }

    private func retireReposition() {
        pendingReposition = nil
        repositionTask?.cancel()
    }

    private func animate(_ changes: (NSAnimationContext) -> Void) {
        animate(changes, completionHandler: {})
    }

    private func animate(
        _ changes: (NSAnimationContext) -> Void,
        completionHandler: @escaping () -> Void
    ) {
        let id = UUID()
        if animations.isEmpty {
            animationEpoch = UUID()
            animationDrain = nil
        }
        animations.insert(id)
        NSAnimationContext.runAnimationGroup(changes) { [self] in
            MainActor.assumeIsolated {
                completionHandler()
                animations.remove(id)
                if animations.isEmpty {
                    let waiter = animationWaiter
                    animationWaiter = nil
                    if let waiter, waiter.0 == animationEpoch { waiter.1.resume() }
                }
            }
        }
    }

    func drain() async {
        cancelPendingWork()
        let task = repositionTask
        let joined = repositionJoin
        await task?.value
        await joined?.value
        if animationDrain == nil, !animations.isEmpty {
            let epoch = animationEpoch
            animationDrain = Task { [self] in
                guard !animations.isEmpty, animationEpoch == epoch else { return }
                await withCheckedContinuation { animationWaiter = (epoch, $0) }
            }
        }
        await animationDrain?.value
    }

    private func applyOrder(_ overlay: NSWindow, below windowNumber: Int?) {
        if let windowNumber {
            overlay.order(.below, relativeTo: windowNumber)
        } else {
            overlay.orderFront(nil)
        }
    }

    nonisolated private static func onScreenWindows(
        primaryHeight: CGFloat
    ) -> [FocusDimWindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return raw.compactMap { entry in
            guard
                let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let number = entry[kCGWindowNumber as String] as? Int,
                let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != myPID,
                let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                let cgRect = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            let cocoaRect = CGRect(
                x: cgRect.minX, y: primaryHeight - cgRect.minY - cgRect.height,
                width: cgRect.width, height: cgRect.height)
            return FocusDimWindowInfo(windowNumber: number, ownerPID: pid, frame: cocoaRect)
        }
    }
}
