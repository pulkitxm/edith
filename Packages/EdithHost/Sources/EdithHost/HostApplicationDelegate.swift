import AppKit
import EdithHostCore
import UserNotifications

@MainActor
final class HostApplicationDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    var notificationClick: (@MainActor (HostHerdrNotificationRequest) async throws -> Void)?
    var shutdown: (@MainActor () async -> Bool)?
    var openMainWindow: (@MainActor () -> Void)?
    var activate: @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var mainWindow: @MainActor () -> NSWindow? = {
        NSApp.windows.first { $0.identifier?.rawValue == "EdithMainWindow" }
    }
    private var terminating = false

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completion([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let request = try? HostHerdrNotificationRequest(
                userInfo: response.notification.request.content.userInfo)
        else { return }
        try? await receiveNotification(request)
    }

    func receiveNotification(_ request: HostHerdrNotificationRequest) async throws {
        guard let notificationClick else { throw HostWorkerError.rejected }
        try await notificationClick(request)
    }

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
