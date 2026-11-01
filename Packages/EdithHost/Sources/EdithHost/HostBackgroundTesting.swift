import AppKit

@MainActor
enum HostBackgroundTesting {
    static let enabled = accepts(
        environment: ProcessInfo.processInfo.environment,
        bundleIdentifier: Bundle.main.bundleIdentifier)

    nonisolated static func accepts(environment: [String: String], bundleIdentifier: String?)
        -> Bool
    {
        environment["EDITH_BACKGROUND_TESTING"] == "1"
            && bundleIdentifier?.hasPrefix("com.pulkit.edith.dev.") == true
    }

    static func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        hide(window)
        window.orderBack(nil)
    }

    static func hide(_ window: NSWindow) {
        guard !(window is NSPanel), window.alphaValue != 0 || !window.ignoresMouseEvents else {
            return
        }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }

    private static var observer: NSObjectProtocol?

    static func install() {
        guard enabled, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow, window.isVisible else { return }
            MainActor.assumeIsolated { hide(window) }
        }
    }
}
