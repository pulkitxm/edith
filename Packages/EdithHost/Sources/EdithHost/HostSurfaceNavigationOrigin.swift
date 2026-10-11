import AppKit
import SwiftUI

struct HostTerminalSurfaceRequest {
    let version: String
    let window: NSWindow
    let validate: @MainActor () throws -> Void
}

@MainActor final class HostSurfaceNavigationOrigin {
    weak var view: NSView?
    var window: NSWindow? { view?.window }

    func validate(window: NSWindow) throws {
        guard let view, view.window === window, !view.isHiddenOrHasHiddenAncestor,
            window.isVisible, !window.isMiniaturized
        else { throw HostWindowNavigationError.unavailable }
    }
}

struct HostSurfaceNavigationAnchor: NSViewRepresentable {
    let origin: HostSurfaceNavigationOrigin
    func makeCoordinator() -> HostSurfaceNavigationOrigin { origin }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        origin.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: HostSurfaceNavigationOrigin) {
        if coordinator.view === view { coordinator.view = nil }
    }
}

private struct HostTerminalWindowsKey: EnvironmentKey {
    static let defaultValue: HostTerminalWindows? = nil
}

extension EnvironmentValues {
    var hostTerminalWindows: HostTerminalWindows? {
        get { self[HostTerminalWindowsKey.self] }
        set { self[HostTerminalWindowsKey.self] = newValue }
    }
}
