import AppKit
import EdithExtensionSupport
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
    var preventsQuit: (@MainActor () async -> Bool)?
    var openMainWindow: (@MainActor () -> Void)?
    var activate: @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var mainWindow: @MainActor () -> NSWindow? = {
        NSApp.windows.first { $0.identifier?.rawValue == "EdithMainWindow" }
    }
    var launchesRuntime = true
    private(set) lazy var runtime = HostRuntime(delegate: self)
    private var terminating = false
    private var deferringQuit = false
    private var quitConfirmed = false
    private var quitCancelled = false
    private(set) var launchedAtLogin = false
    private var windowCloseObserver: NSObjectProtocol?
    private var windowKeyObserver: NSObjectProtocol?

    static func applyConfiguredActivationPolicy(defaults: UserDefaults = SharedDefaults.store) {
        let showsDock =
            defaults.object(forKey: AppStorageKeys.General.showDockIcon) as? Bool ?? true
        NSApp.setActivationPolicy(showsDock ? .regular : .accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    static func presentsApplication(_ window: NSWindow) -> Bool {
        window.canBecomeMain && !(window is NSPanel)
    }

    private func appearInDockWhilePresenting() {
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard Self.presentsApplication(window), NSApp.activationPolicy() == .accessory
                else { return }
                Self.applyConfiguredActivationPolicy()
            }
        }
    }

    private func dropToAccessoryWhenWindowless() {
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async {
                let presenting = NSApp.windows.contains {
                    ($0.isVisible || $0.isMiniaturized) && Self.presentsApplication($0)
                }
                if !presenting { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

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
        if NSApp.activationPolicy() == .accessory { Self.applyConfiguredActivationPolicy() }
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
        Self.applyConfiguredActivationPolicy()
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
        TextEditingCommands.install()
        ScrollForwarding.install()
        dropToAccessoryWhenWindowless()
        appearInDockWhilePresenting()
        if launchesRuntime { runtime.launch() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if deferringQuit { quitCancelled = true }
        showMainWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        if let preventsQuit, !quitConfirmed {
            guard !deferringQuit else { return .terminateCancel }
            deferringQuit = true
            quitCancelled = false
            Task {
                if await preventsQuit() {
                    NSApp.hide(nil)
                    while !quitCancelled, await preventsQuit() {
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                deferringQuit = false
                guard !quitCancelled else { return }
                quitConfirmed = true
                HostQuit.terminate()
                quitConfirmed = false
            }
            return .terminateCancel
        }
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
