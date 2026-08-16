import AppKit
import CoreGraphics
import EdithKit

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

    init() {
        FocusDimHotKey.register()
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

    func shutdown() {
        FocusDimHotKey.unregister()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let activationObserver { workspaceCenter.removeObserver(activationObserver) }
        if let spaceObserver { workspaceCenter.removeObserver(spaceObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        activationObserver = nil
        spaceObserver = nil
        screenObserver = nil

        let windows = Array(overlays.values)
        overlays.removeAll()
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = animationDuration
                windows.forEach { $0.animator().alphaValue = 0 }
            },
            completionHandler: {
                windows.forEach { $0.orderOut(nil) }
            })
    }

    func applySettings() {
        FocusDimHotKey.register()
        let previousMode = displayMode
        loadSettings()
        guard CGPreflightScreenCaptureAccess(), FocusDimState.isActive() else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animationDuration
                overlays.values.forEach { $0.animator().alphaValue = 0 }
            }
            return
        }
        if displayMode != previousMode {
            reposition(animateIn: false)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
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
        guard CGPreflightScreenCaptureAccess(), FocusDimState.isActive() else {
            overlays.values.forEach { $0.alphaValue = 0 }
            return
        }
        let windows = Self.onScreenWindows()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        var targets: [(FocusDimOverlayWindow, Int?)] = []
        for screen in NSScreen.screens {
            guard let id = screen.focusDimDisplayID, let overlay = overlays[id] else { continue }
            let reference = FocusDimSelection.referenceWindow(
                forScreen: screen.frame, frontmostPID: frontmostPID,
                windowsFrontToBack: windows, mode: displayMode)
            targets.append((overlay, reference?.windowNumber))
        }

        if animateIn {
            for (overlay, windowNumber) in targets {
                applyOrder(overlay, below: windowNumber)
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                targets.forEach { $0.0.animator().alphaValue = self.intensity }
            }
            return
        }

        let halfDuration = animationDuration / 2
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = halfDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                targets.forEach { $0.0.animator().alphaValue = 0 }
            },
            completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (overlay, windowNumber) in targets {
                        self.applyOrder(overlay, below: windowNumber)
                    }
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = halfDuration
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        targets.forEach { $0.0.animator().alphaValue = self.intensity }
                    }
                }
            })
    }

    private func applyOrder(_ overlay: NSWindow, below windowNumber: Int?) {
        if let windowNumber {
            overlay.order(.below, relativeTo: windowNumber)
        } else {
            overlay.orderFront(nil)
        }
    }

    private static func onScreenWindows() -> [FocusDimWindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
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
