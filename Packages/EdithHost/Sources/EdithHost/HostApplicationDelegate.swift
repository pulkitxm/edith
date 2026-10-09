import AppKit

@MainActor
final class HostApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdown: (@MainActor () async -> Void)?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard let shutdown else { return .terminateNow }
        terminating = true
        Task {
            await shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
