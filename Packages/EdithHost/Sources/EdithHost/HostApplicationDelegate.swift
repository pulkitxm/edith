import AppKit

@MainActor
final class HostApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdown: (@MainActor () async -> Bool)?
    private var terminating = false

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
