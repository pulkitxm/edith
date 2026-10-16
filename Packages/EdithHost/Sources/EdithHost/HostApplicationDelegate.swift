import AppKit
import EdithExtensionUI
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
    var launchesRuntime = true
    private(set) lazy var runtime = HostRuntime(delegate: self)
    private var terminating = false
    private(set) var launchedAtLogin = false

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
        } else if let openMainWindow {
            openMainWindow()
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL, configuration: configuration)
        }
        activate()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin =
            event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuit(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        HostQuit.terminate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        InputFocus.install()
        ScrollForwarding.install()
        if launchesRuntime { runtime.launch() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        HostQuit.conceal()
        NSApp.setActivationPolicy(.prohibited)
        let finish = { [weak self] in
            self?.stopWorkers?()
            exit(0)
        }
        Task {
            await shutdown()
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { finish() }
        return .terminateCancel
    }
}
