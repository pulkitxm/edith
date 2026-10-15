import AppKit
import EdithHostCore
import UserNotifications

@MainActor
final class HostApplicationDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    var notificationClick: (@MainActor (HostHerdrNotificationRequest) async throws -> Void)?
    var shutdown: (@MainActor () async -> Void)?
    var stopWorkers: (@MainActor () -> Void)?
    var openMainWindow: (@MainActor () -> Void)?
    var activate: @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var mainWindow: @MainActor () -> NSWindow? = {
        NSApp.windows.first { $0.identifier?.rawValue == "EdithMainWindow" }
    }
    private var terminating = false
    private(set) var launchedAtLogin = false
    private var replied = false
    static let shutdownGrace: Duration = .seconds(5)

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

    func showMainWindow(_ ownedWindow: NSWindow? = nil) {
        if let window = ownedWindow ?? mainWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.attachedSheet?.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        activate()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin =
            event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard let shutdown else { return .terminateNow }
        terminating = true
        let finish = { [weak self] in
            guard let self, !self.replied else { return }
            self.replied = true
            self.stopWorkers?()
            sender.reply(toApplicationShouldTerminate: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        }
        Task {
            await shutdown()
            finish()
        }
        Task {
            try? await Task.sleep(for: Self.shutdownGrace)
            finish()
        }
        return .terminateLater
    }
}
