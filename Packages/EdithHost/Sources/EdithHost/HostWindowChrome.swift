import AppKit
import EdithExtensionSupport
import SwiftUI

struct HostWindowChrome: NSViewRepresentable {
    let persist: Bool
    @Binding var fullscreen: Bool
    func makeNSView(context: Context) -> NSView {
        Sentinel(persist: persist, update: { fullscreen = $0 })
    }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class Sentinel: NSView {
        let persist: Bool
        let update: (Bool) -> Void
        private weak var configuredWindow: NSWindow?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        init(persist: Bool, update: @escaping (Bool) -> Void) {
            self.persist = persist; self.update = update
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, configuredWindow !== window else { return }
            configuredWindow = window
            window.styleMask.insert(.fullSizeContentView)
            window.title = "Edith"
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none; window.isRestorable = false
            window.tabbingMode = .disallowed
            window.identifier = NSUserInterfaceItemIdentifier("EdithMainWindow")
            let visible =
                window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            window.contentMinSize = HostWindowFramePolicy.minimumSize(visibleFrame: visible)
            guard persist else { return }
            let name = "EdithMainWindow"
            let key = HostWindowFramePolicy.autosaveKey(name: name)
            if HostWindowFramePolicy.shouldDiscardAutosave(
                UserDefaults.standard.string(forKey: key))
            {
                NSWindow.removeFrame(usingName: name)
                UserDefaults.standard.removeObject(forKey: key)
            }
            window.setContentSize(HostWindowFramePolicy.defaultSize(visibleFrame: visible))
            window.center()
            window.setFrameAutosaveName(name)
            let launch = HostWindowFramePolicy.normalizedFrame(window.frame, visibleFrame: visible)
            if window.isZoomed { window.zoom(nil) }
            window.setFrame(launch, display: false)
            window.saveFrame(usingName: name)
            let center = NotificationCenter.default
            for notification in [
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            ] {
                observers.append(
                    center.addObserver(forName: notification, object: window, queue: .main) {
                        [weak self, weak window] _ in
                        MainActor.assumeIsolated {
                            guard let self, let window else { return }
                            let value = window.styleMask.contains(.fullScreen)
                            UserDefaults.standard.set(
                                value, forKey: AppStorageKeys.General.editMainWindowFullScreen)
                            self.update(value)
                        }
                    })
            }
            if ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] == nil,
                UserDefaults.standard.bool(forKey: AppStorageKeys.General.editMainWindowFullScreen),
                !window.styleMask.contains(.fullScreen)
            {
                window.toggleFullScreen(nil)
            }
        }
    }
}
