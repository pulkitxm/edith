import AppKit
import GhosttyKit

final class GhosttySurfaceRegistry {
    static let shared = GhosttySurfaceRegistry()

    private final class WeakView {
        weak var value: GhosttyTerminalView?

        init(_ value: GhosttyTerminalView) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var views: [UInt: WeakView] = [:]

    private init() {}

    func register(_ view: GhosttyTerminalView) {
        let key = UInt(bitPattern: Unmanaged.passUnretained(view).toOpaque())
        lock.withLock { views[key] = WeakView(view) }
    }

    func unregister(_ view: GhosttyTerminalView) {
        let key = UInt(bitPattern: Unmanaged.passUnretained(view).toOpaque())
        _ = lock.withLock { views.removeValue(forKey: key) }
    }

    func view(_ userdata: UnsafeMutableRawPointer?) -> GhosttyTerminalView? {
        guard let userdata else { return nil }
        return lock.withLock { views[UInt(bitPattern: userdata)]?.value }
    }

    func surface(_ userdata: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        view(userdata)?.surface
    }

    func view(_ target: ghostty_target_s) -> GhosttyTerminalView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else {
            return nil
        }
        return view(ghostty_surface_userdata(surface))
    }

    func render(_ target: ghostty_target_s) {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return }
        guard let surface = target.target.surface else { return }
        guard let userdata = ghostty_surface_userdata(surface) else { return }
        view(userdata)?.scheduleDraw()
    }

    func requestClose(_ target: ghostty_target_s) {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return }
        guard let surface = target.target.surface else { return }
        guard let userdata = ghostty_surface_userdata(surface) else { return }
        view(userdata)?.reportClosed()
    }

    func close(_ userdata: UnsafeMutableRawPointer?) {
        view(userdata)?.reportClosed()
    }

    func forwardModifierChange(_ event: NSEvent) {
        let registered = lock.withLock { views.values.compactMap(\.value) }
        let eventWindow = event.window ?? NSApp.keyWindow
        for view in registered {
            let matchesWindow = eventWindow != nil && eventWindow === view.window
            guard
                GhosttyTerminalView.shouldForwardLocalModifier(
                    matchesWindow: matchesWindow, focused: view.window?.firstResponder === view)
            else { continue }
            let mouseOverSurface =
                view.renderingActive && !view.isHidden && view.mouseOverSurface
            view.applyModifierChange(event, mouseOverSurface: mouseOverSurface)
        }
    }
}
