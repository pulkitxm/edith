import AppKit
import Carbon.HIToolbox
import CoreGraphics
import EdithKit
import ScreenCaptureKit

@MainActor
final class PixelRulerStore: ObservableObject, FeatureModule {
    private var windows: [PixelRulerOverlayWindow] = []
    private var activating = false

    init() {
        registerHotKey()
        _ = Self.requestScreenRecordingAccessIfNeeded()
    }

    func shutdown() {
        GlobalHotKey.clear(id: GlobalHotKey.ID.pixelRuler)
        teardown()
    }

    func registerHotKey() {
        GlobalHotKey.set(
            id: GlobalHotKey.ID.pixelRuler, keyCode: PixelRulerHotKey.code,
            modifiers: PixelRulerHotKey.mods
        ) { [weak self] in
            self?.activate()
        }
    }

    func activate() {
        guard windows.isEmpty, !activating else { return }
        activating = true
        Task { @MainActor in
            let granted = Self.requestScreenRecordingAccessIfNeeded()
            let captures = granted ? await Self.captureAllScreens() : [:]
            windows = NSScreen.screens.map { screen in
                let capture = screen.pixelRulerDisplayID.flatMap { captures[$0] }
                return PixelRulerOverlayWindow(
                    screen: screen, capture: capture,
                    hint: PixelRulerCaptureHint.hint(granted: granted, hasCapture: capture != nil)
                ) { [weak self] in
                    self?.teardown()
                }
            }
            guard !windows.isEmpty else {
                activating = false
                return
            }
            let mouseLocation = NSEvent.mouseLocation
            let activeScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            NSApp.activate(ignoringOtherApps: true)
            for window in windows {
                if window.hostScreen === activeScreen {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    window.orderFrontRegardless()
                }
            }
            activating = false
        }
    }

    private func teardown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        activating = false
    }

    private static func requestScreenRecordingAccessIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    private static func captureAllScreens() async -> [CGDirectDisplayID: PixelRulerCapture] {
        guard let content = try? await SCShareableContent.current else { return [:] }
        var result: [CGDirectDisplayID: PixelRulerCapture] = [:]
        for screen in NSScreen.screens {
            guard let displayID = screen.pixelRulerDisplayID,
                let display = content.displays.first(where: { $0.displayID == displayID })
            else { continue }
            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.showsCursor = false
            config.scalesToFit = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            guard
                let cgImage = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config),
                let buffer = PixelRulerPixelBuffer(cgImage: cgImage)
            else { continue }
            result[displayID] = PixelRulerCapture(cgImage: cgImage, buffer: buffer)
        }
        return result
    }
}

enum PixelRulerCaptureHint {
    static func hint(granted: Bool, hasCapture: Bool) -> String? {
        if hasCapture { return nil }
        if granted {
            return
                "Screen capture failed, so the screen isn't frozen. Quit and reopen Edith, or re-toggle Edith Menu Bar in System Settings > Privacy & Security > Screen Recording."
        }
        return
            "Screen Recording is off, so the screen isn't frozen. Allow Edith Menu Bar in System Settings > Privacy & Security > Screen Recording, then relaunch Edith."
    }
}

enum PixelRulerHotKey {
    static var code: Int {
        SharedDefaults.store.object(forKey: "pixelRulerHotKeyCode") as? Int ?? kVK_ANSI_R
    }
    static var mods: Int {
        SharedDefaults.store.object(forKey: "pixelRulerHotKeyMods") as? Int
            ?? (cmdKey | optionKey | controlKey)
    }
    static var label: String {
        SharedDefaults.store.string(forKey: "pixelRulerHotKeyLabel") ?? "⌃⌥⌘R"
    }
}

extension NSScreen {
    fileprivate var pixelRulerDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
