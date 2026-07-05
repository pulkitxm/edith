import AppKit
import SwiftUI

@MainActor
enum DashboardWindow {
    private static var window: NSWindow?

    static func open(store: UsageStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "Edith — Usage"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(
            rootView: DashboardView().environmentObject(store))
        w.delegate = DashboardWindowDelegate.shared
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func forget() { window = nil }
}

@MainActor
final class DashboardWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowDelegate()
    func windowWillClose(_ notification: Notification) {
        DashboardWindow.forget()
    }
}
