import AppKit
import GhosttyKit

final class GhosttySurfaceRegistry {
    static let shared = GhosttySurfaceRegistry()

    private var views: [ObjectIdentifier: GhosttyTerminalView] = [:]

    private init() {}

    func register(_ view: GhosttyTerminalView) {
        views[ObjectIdentifier(view)] = view
    }

    func unregister(_ view: GhosttyTerminalView) {
        views.removeValue(forKey: ObjectIdentifier(view))
    }

    func view(_ userdata: UnsafeMutableRawPointer?) -> GhosttyTerminalView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    func surface(_ userdata: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        view(userdata)?.surface
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
}
