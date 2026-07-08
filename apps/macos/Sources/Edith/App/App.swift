import EdithKit
import ServiceManagement
import SwiftUI

private let helperBundleIdentifier = "com.pulkit.edith.bar"

@MainActor
final class MainAppDelegate: NSObject, NSApplicationDelegate {
    private var quitObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var settingsChangeDebounce: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance(SharedDefaults.store.string(forKey: "appearance") ?? "system")
        let showDockIcon = SharedDefaults.store.object(forKey: "showDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        launchHelperIfNeeded()
        Task { await DashboardModel.shared.load() }
        nudgePermissionsOnFirstLaunch()
        MainWindow.open()
        quitObserver = IPC.observe(IPC.Name.quitMainApp) {
            NSApp.terminate(nil)
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: SharedDefaults.store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSettingsChangedBroadcast() }
        }
    }

    private func scheduleSettingsChangedBroadcast() {
        settingsChangeDebounce?.invalidate()
        settingsChangeDebounce = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            IPC.post(IPC.Name.settingsChanged)
        }
    }

    private func nudgePermissionsOnFirstLaunch() {
        let store = SharedDefaults.store
        guard store.object(forKey: "hasPromptedPermissions") == nil else { return }
        store.set(true, forKey: "hasPromptedPermissions")
        if PermissionsStatus.current {
            store.set(MainDestination.permissions.rawValue, forKey: "mainWindowSection")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainWindow.open() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private let retiredHelperBundleIdentifier = "com.pulkit.edith.menubar"

private func launchHelperIfNeeded() {
    let retired = SMAppService.loginItem(identifier: retiredHelperBundleIdentifier)
    if retired.status == .enabled {
        try? retired.unregister()
    }
    let service = SMAppService.loginItem(identifier: helperBundleIdentifier)
    if service.status != .enabled {
        try? service.register()
    }
    guard
        NSRunningApplication.runningApplications(
            withBundleIdentifier: helperBundleIdentifier
        ).isEmpty
    else { return }
    let helperURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Library/LoginItems/EdithMenuBar.app")
    NSWorkspace.shared.openApplication(
        at: helperURL, configuration: NSWorkspace.OpenConfiguration())
}

@main
struct EdithApp: App {
    @NSApplicationDelegateAdaptor(MainAppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            Text("Edith settings live in the menu bar for now — click the panel icon.")
                .padding(24)
                .frame(width: 340)
        }
    }
}
