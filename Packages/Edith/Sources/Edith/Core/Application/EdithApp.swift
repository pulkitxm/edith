import EdithKit
import ServiceManagement
import SwiftUI

private let helperBundleIdentifier = MainApp.statusBarBundleIdentifier

@MainActor
final class MainAppDelegate: NSObject, NSApplicationDelegate {
    private var quitObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var settingsChangeDebounce: Timer?
    private var appStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance(
            SharedDefaults.store.string(forKey: AppStorageKeys.General.appearance) ?? "system")
        InputFocus.install()
        ScrollForwarding.install()
        RetiredLicenseCleanup.run()
        FinderUndoBridge.start()
        startApp()
        SectionWindowMenu.install()
    }

    private func startApp() {
        guard !appStarted else {
            showInitialWindow()
            return
        }
        appStarted = true
        ExtensionDefaultsMigration.migrate()
        Repo.prepareStoredPaths()
        applyConfiguredActivationPolicy()
        launchHelperIfNeeded()
        let dashboard = DashboardModel.shared
        dashboard.syncExtensionState()
        if SharedDefaults.store.bool(forKey: AppStorageKeys.Tabs.usageEnabled) {
            Task { await dashboard.load() }
        }
        showInitialWindow()
        quitObserver = IPC.observe(IPC.Name.quitMainApp) {
            NSApp.terminate(nil)
        }
        CLIWindowBridge.install()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: SharedDefaults.store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DashboardModel.shared.syncExtensionState()
                self?.scheduleSettingsChangedBroadcast()
            }
        }
    }

    private func applyConfiguredActivationPolicy() {
        let showDockIcon =
            SharedDefaults.store.object(forKey: AppStorageKeys.General.showDockIcon) as? Bool
            ?? true
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    private func showInitialWindow() {
        if OnboardingFlow.shouldShowOnboarding() {
            OnboardingWindow.open()
        } else {
            MainWindow.open()
        }
    }

    private func scheduleSettingsChangedBroadcast() {
        settingsChangeDebounce?.invalidate()
        settingsChangeDebounce = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            IPC.post(IPC.Name.settingsChanged)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !appStarted {
            startApp()
        } else if !hasVisibleWindows {
            showInitialWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if settingsChangeDebounce?.isValid == true {
            IPC.post(IPC.Name.settingsChanged)
        }
        settingsChangeDebounce?.invalidate()
        settingsChangeDebounce = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private let retiredHelperBundleIdentifiers = [
    "com.pulkit.edith.panel", "com.pulkit.edith.bar", "com.pulkit.edith.menubar",
]

private func launchHelperIfNeeded() {
    for identifier in retiredHelperBundleIdentifiers {
        let retired = SMAppService.loginItem(identifier: identifier)
        if retired.status == .enabled {
            try? retired.unregister()
        }
    }
    let service = SMAppService.loginItem(identifier: helperBundleIdentifier)
    if service.status != .enabled {
        try? service.register()
    }
    let helperURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Library/LoginItems/Edith.app")
    if let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: helperBundleIdentifier
    ).first {
        guard let installedAt = helperInstalledDate(helperURL),
            let launchedAt = running.launchDate, launchedAt < installedAt
        else { return }
        running.forceTerminate()
        relaunchHelper(at: helperURL, after: running)
        return
    }
    NSWorkspace.shared.openApplication(
        at: helperURL, configuration: NSWorkspace.OpenConfiguration())
}

private func helperInstalledDate(_ helperURL: URL) -> Date? {
    let exec = helperURL.appendingPathComponent("Contents/MacOS/Edith")
    return (try? FileManager.default.attributesOfItem(atPath: exec.path)[.modificationDate])
        as? Date
}

private func relaunchHelper(at url: URL, after proc: NSRunningApplication) {
    DispatchQueue.global(qos: .userInitiated).async {
        for _ in 0..<50 where !proc.isTerminated {
            Thread.sleep(forTimeInterval: 0.1)
        }
        DispatchQueue.main.async {
            NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

public struct EdithApp: App {
    @NSApplicationDelegateAdaptor(MainAppDelegate.self) private var delegate

    public init() {
        _ = AskpassEntry.runIfRequested()
    }

    public var body: some Scene {
        Settings {
            SettingsRedirect()
        }
    }
}

private struct SettingsRedirect: View {
    var body: some View {
        Color.clear
            .frame(width: UIScale.pt(1), height: UIScale.pt(1))
            .onAppear {
                SharedDefaults.store.set(
                    MainDestination.settings.rawValue,
                    forKey: AppStorageKeys.General.mainWindowSection)
                DispatchQueue.main.async {
                    for window in NSApp.windows
                    where window.identifier?.rawValue.contains("Settings") == true
                        || window.title == "Edith Settings"
                    {
                        window.close()
                    }
                    MainWindow.open()
                }
            }
    }
}
