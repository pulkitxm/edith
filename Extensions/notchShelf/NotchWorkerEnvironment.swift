import AppKit
import EdithExtensionSupport
import Foundation

typealias NotchTab = SurfaceNotchTab

@MainActor
enum NotchWorkerPresentation {
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["EDITH_BACKGROUND_TESTING"] == "1"
    }

    static func orderFrontRegardless(_ window: NSWindow) {
        if !isTesting { window.orderFrontRegardless() }
    }

    static func makeKey(_ window: NSWindow?) {
        if !isTesting { window?.makeKey() }
    }

    static func activate(ignoringOtherApps: Bool) {
        if !isTesting { NSApp.activate(ignoringOtherApps: ignoringOtherApps) }
    }

    static func openPrivacySettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

enum NotchWorkerIPC {
    enum Name {
        static let shelfChanged = "shelfChanged"
        static let shelfOperation = "shelfOperation"
        static let shelfOperationResult = "shelfOperationResult"
        static let settingsChanged = "settingsChanged"
        static let permissionsRefreshed = "permissionsRefreshed"
        static let requestNotchBrowserAction = "requestNotchBrowserAction"
        static let notchBrowserActionResult = "notchBrowserActionResult"
    }

    static func post(_ name: String, userInfo: [String: Any]? = nil) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name(name), object: nil, userInfo: userInfo)
        }
    }

    static func observe(_ name: String, _ action: @escaping () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { _ in action() }
    }

    static func observe(_ name: String, info: @escaping ([AnyHashable: Any]) -> Void)
        -> NSObjectProtocol
    {
        NotificationCenter.default.addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { note in info(note.userInfo ?? [:]) }
    }

    static func stopObserving(_ observer: NSObjectProtocol?) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

@MainActor @Observable
final class NotchPresenterState {
    enum Scope { case browser, camera }
    static let shared = NotchPresenterState()
    var privacy: SurfacePrivacyState?

    func hides(_ scope: Scope) -> Bool {
        guard let values = privacy?.values, values["active"] == "1" else { return false }
        let key = scope == .browser ? "blurBrowser" : "blurCamera"
        return values[key] != "0"
    }
}
