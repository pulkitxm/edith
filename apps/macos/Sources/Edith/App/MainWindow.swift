import AppKit
import SwiftUI

@MainActor
enum MainWindow {
    private static var window: NSWindow?

    static func open() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "Edith"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: MainWindowView())
        w.delegate = MainWindowDelegate.shared
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func forget() { window = nil }
}

@MainActor
final class MainWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = MainWindowDelegate()
    func windowWillClose(_ notification: Notification) {
        MainWindow.forget()
    }
}
