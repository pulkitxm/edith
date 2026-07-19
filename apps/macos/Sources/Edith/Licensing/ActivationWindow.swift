import AppKit
import EdithKit
import SwiftUI

@MainActor
enum ActivationWindow {
    static let identifier = NSUserInterfaceItemIdentifier("EdithActivationWindow")

    private static var window: NSWindow?

    static func open(
        licenseState: LicenseState,
        client: LicenseClient,
        onActivated: @escaping () -> Void
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let activationWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 440),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        activationWindow.identifier = identifier
        activationWindow.title = "Activate Edith"
        activationWindow.titleVisibility = .hidden
        activationWindow.titlebarAppearsTransparent = true
        activationWindow.titlebarSeparatorStyle = .none
        activationWindow.isMovableByWindowBackground = true
        activationWindow.isReleasedWhenClosed = false
        let hosting = NSHostingController(
            rootView: ActivationView(licenseState: licenseState, client: client) {
                close()
                onActivated()
            })
        hosting.sizingOptions = []
        activationWindow.contentViewController = hosting
        activationWindow.setContentSize(NSSize(width: 440, height: 440))
        activationWindow.center()
        window = activationWindow
        activationWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func close() {
        window?.close()
        window = nil
    }
}
