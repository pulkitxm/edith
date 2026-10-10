import AppKit

@MainActor
final class HostApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdown: (@MainActor () async -> Bool)?
    var openMainWindow: (@MainActor () -> Void)?
    var activate: @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var mainWindow: @MainActor () -> NSWindow? = {
        NSApp.windows.first { $0.identifier?.rawValue == "EdithMainWindow" }
    }
    private var terminating = false

    func showMainWindow() {
        if let window = mainWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard let shutdown else { return .terminateNow }
        terminating = true
        Task {
            let ready = await shutdown()
            if !ready {
                terminating = false
                let alert = NSAlert()
                alert.messageText = "An extension could not restore its system settings"
                alert.informativeText =
                    "Edith remains open. Open the enabled extension, restore its settings, then quit again."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: ready)
        }
        return .terminateLater
    }
}
