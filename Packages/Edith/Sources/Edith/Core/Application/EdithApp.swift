import EdithKit
import Security
import ServiceManagement
import SwiftUI

private let helperBundleIdentifier = MainApp.statusBarBundleIdentifier

@MainActor
final class MainAppDelegate: NSObject, NSApplicationDelegate {
    private var quitObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var settingsBroadcastPending = false
    private var lastUsageEnabled: Bool?
    private var appStarted = false
    private var launchCleanupTask: Task<Void, Never>?
    private var helperMaintenanceTask: Task<Void, Never>?
    private let lidAwakeDaemonRegistrar = LidAwakeDaemonRegistrar()
    private let postLaunch = StartupCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchTrace = PerformanceTrace.begin(.startup, "main.launch")
        defer { PerformanceTrace.end(launchTrace) }
        applyAppearance(
            SharedDefaults.store.string(forKey: AppStorageKeys.General.appearance) ?? "system")
        InputFocus.install()
        ScrollForwarding.install()
        FinderUndoBridge.start()
        startApp()
    }

    private func startApp() {
        guard !appStarted else {
            showInitialWindow()
            return
        }
        appStarted = true
        ExtensionDefaultsMigration.migrate()
        lidAwakeDaemonRegistrar.register()
        applyConfiguredActivationPolicy()
        showInitialWindow()
        PerformanceTrace.event(.mainThread, "main.initialWindow")
        quitObserver = IPC.observe(IPC.Name.quitMainApp) {
            AppRuntimeCenter().perform(.quit) { NSApp.terminate(nil) }
        }
        CLIWindowBridge.install()
        lastUsageEnabled =
            SharedDefaults.store.object(forKey: AppStorageKeys.Tabs.usageEnabled) as? Bool
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: SharedDefaults.store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSettingsChange()
            }
        }
        postLaunch.start([
            StartupPhase(name: "main.launchCleanup") { [weak self] in
                guard let self else { return }
                self.launchCleanupTask?.cancel()
                self.launchCleanupTask = Task.detached(priority: .utility) {
                    Repo.prepareStoredPaths()
                    RetiredLicenseCleanup.run()
                }
            },
            StartupPhase(name: "main.helper") { [weak self] in
                guard let self else { return }
                self.helperMaintenanceTask?.cancel()
                self.helperMaintenanceTask = Task.detached(priority: .utility) {
                    await launchHelperIfNeeded()
                }
            },
            StartupPhase(name: "main.sectionMenu") { SectionWindowMenu.install() },
        ])
    }

    private func handleSettingsChange() {
        let usageEnabled =
            SharedDefaults.store.object(forKey: AppStorageKeys.Tabs.usageEnabled) as? Bool
        if usageEnabled != lastUsageEnabled {
            lastUsageEnabled = usageEnabled
            DashboardModel.shared.syncExtensionState()
        }
        scheduleSettingsChangedBroadcast()
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
        guard !settingsBroadcastPending else { return }
        settingsBroadcastPending = true
        ProcessInfo.processInfo.disableSuddenTermination()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.flushSettingsChangedBroadcast()
            }
        }
    }

    private func flushSettingsChangedBroadcast() {
        guard settingsBroadcastPending else { return }
        settingsBroadcastPending = false
        IPC.post(IPC.Name.settingsChanged)
        ProcessInfo.processInfo.enableSuddenTermination()
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
        flushSettingsChangedBroadcast()
        launchCleanupTask?.cancel()
        helperMaintenanceTask?.cancel()
        postLaunch.cancel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private final class LidAwakeDaemonRegistrar {
    private static let fingerprintKey = "lidAwakePrivilegedHelperFingerprint"

    private let service = SMAppService.daemon(plistName: LidAwakePrivilegedService.plistName)
    private var registrationInFlight = false

    func register() {
        guard !registrationInFlight else { return }
        let fingerprint = helperFingerprint()
        switch service.status {
        case .enabled, .requiresApproval:
            guard let fingerprint else { return }
            guard UserDefaults.standard.string(forKey: Self.fingerprintKey) != fingerprint
            else { return }
            registrationInFlight = true
            service.unregister { [weak self] error in
                guard let self else { return }
                self.registrationInFlight = false
                guard error == nil else { return }
                self.registerCurrent(fingerprint: fingerprint)
            }
        case .notRegistered, .notFound:
            registerCurrent(fingerprint: fingerprint)
        @unknown default:
            break
        }
    }

    private func registerCurrent(fingerprint: String?) {
        do {
            try service.register()
            persist(fingerprint)
        } catch {
            let failure = error as NSError
            if service.status == .requiresApproval
                || (failure.domain == "SMAppServiceErrorDomain" && failure.code == 1)
            {
                persist(fingerprint)
            } else {
                NSLog(
                    "Service Management registration failed (%@ %ld): %@", failure.domain,
                    failure.code, failure.localizedDescription)
            }
        }
    }

    private func persist(_ fingerprint: String?) {
        if let fingerprint {
            UserDefaults.standard.set(fingerprint, forKey: Self.fingerprintKey)
        }
    }

    private func helperFingerprint() -> String? {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/PrivilegedHelperTools")
            .appendingPathComponent(LidAwakePrivilegedService.bundleIdentifier)
        var code: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess,
            let code
        else { return nil }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
            let values = information as? [CFString: Any],
            let data = values[kSecCodeInfoUnique] as? Data
        else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

private let retiredHelperBundleIdentifiers = [
    "com.pulkit.edith.panel", "com.pulkit.edith.bar", "com.pulkit.edith.menubar",
]

private func launchHelperIfNeeded() async {
    for identifier in retiredHelperBundleIdentifiers {
        let retired = SMAppService.loginItem(identifier: identifier)
        if retired.status == .enabled {
            try? await retired.unregister()
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
        await MainActor.run {
            running.forceTerminate()
            relaunchHelper(at: helperURL, after: running)
        }
        return
    }
    await MainActor.run {
        NSWorkspace.shared.openApplication(
            at: helperURL, configuration: NSWorkspace.OpenConfiguration())
    }
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
